#include "AudioBridgeFDBroker.hpp"

#include <fcntl.h>
#include <pwd.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>

namespace cardputer_bridge::audio_ipc {
namespace {

constexpr std::size_t kMappingSize = sizeof(SharedAudioBuffer);

bool IsTestMode() noexcept {
    const char* value = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
    return value != nullptr && std::strcmp(value, "1") == 0;
}

void StoreRelease(UInt32* destination, UInt32 value) noexcept {
    __atomic_store_n(destination, value, __ATOMIC_RELEASE);
}

void StoreRelease(std::uint64_t* destination, std::uint64_t value) noexcept {
    __atomic_store_n(destination, value, __ATOMIC_RELEASE);
}

void Deactivate(SharedAudioBuffer* buffer) noexcept {
    if (buffer != nullptr) {
        StoreRelease(&buffer->producer_active, 0);
        StoreRelease(&buffer->lease_deadline_host_time, 0);
    }
}

SharedAudioBuffer* Map(int descriptor) noexcept {
    void* mapping = mmap(
        nullptr,
        kMappingSize,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0);
    return mapping == MAP_FAILED ? nullptr : static_cast<SharedAudioBuffer*>(mapping);
}

void SetCloseOnExec(int descriptor) noexcept {
    if (descriptor >= 0) {
        const int flags = fcntl(descriptor, F_GETFD);
        if (flags >= 0) {
            fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
        }
    }
}

void DisableSigPipe(int descriptor) noexcept {
    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
}

bool SafeSocketPath(const std::string& path) noexcept {
    return !path.empty()
        && path.front() == '/'
        && path.size() < sizeof(sockaddr_un::sun_path)
        && path.find("..") == std::string::npos;
}

bool RemoveOwnedSocket(const std::string& path, std::uint64_t device, std::uint64_t inode) {
    if (device == 0 || inode == 0) {
        return false;
    }
    struct stat metadata{};
    if (lstat(path.c_str(), &metadata) != 0) {
        return errno == ENOENT;
    }
    if (!S_ISSOCK(metadata.st_mode)
        || metadata.st_uid != geteuid()
        || static_cast<std::uint64_t>(metadata.st_dev) != device
        || static_cast<std::uint64_t>(metadata.st_ino) != inode) {
        return false;
    }
    return unlink(path.c_str()) == 0;
}

bool RemoveStaleOwnedSocket(const std::string& path) noexcept {
    struct stat before{};
    if (lstat(path.c_str(), &before) != 0) {
        return errno == ENOENT;
    }
    if (!S_ISSOCK(before.st_mode) || before.st_uid != geteuid()) {
        return false;
    }

    const int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0) {
        return false;
    }
    SetCloseOnExec(probe);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    const int connected = connect(
        probe,
        reinterpret_cast<const sockaddr*>(&address),
        sizeof(address));
    const int connectError = errno;
    close(probe);
    if (connected == 0 || connectError != ECONNREFUSED) {
        return false;
    }

    struct stat after{};
    if (lstat(path.c_str(), &after) != 0
        || !S_ISSOCK(after.st_mode)
        || after.st_uid != geteuid()
        || before.st_dev != after.st_dev
        || before.st_ino != after.st_ino) {
        return false;
    }
    return unlink(path.c_str()) == 0;
}

int AcquireOwnershipLock(const std::string& socketPath) noexcept {
    const std::string lockPath = socketPath + ".lock";
    if (!SafeSocketPath(lockPath)) {
        return -1;
    }
    const int descriptor = open(
        lockPath.c_str(),
        O_CREAT | O_RDWR | O_NOFOLLOW,
        0600);
    if (descriptor < 0) {
        return -1;
    }
    SetCloseOnExec(descriptor);
    struct stat metadata{};
    if (fstat(descriptor, &metadata) != 0
        || !S_ISREG(metadata.st_mode)
        || metadata.st_uid != geteuid()
        || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        close(descriptor);
        return -1;
    }
    if (fchmod(descriptor, 0600) != 0) {
        flock(descriptor, LOCK_UN);
        close(descriptor);
        return -1;
    }
    return descriptor;
}

void CloseReceivedRights(msghdr& message, int* acceptedDescriptor, bool* valid) noexcept {
    int receivedCount = 0;
    int candidate = -1;
    bool shapeValid = true;
    for (cmsghdr* header = CMSG_FIRSTHDR(&message);
         header != nullptr;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS
            || header->cmsg_len < CMSG_LEN(0)) {
            shapeValid = false;
            continue;
        }
        const std::size_t payloadBytes = header->cmsg_len - CMSG_LEN(0);
        if (payloadBytes == 0 || payloadBytes % sizeof(int) != 0) {
            shapeValid = false;
            continue;
        }
        const std::size_t descriptorCount = payloadBytes / sizeof(int);
        const int* descriptors = reinterpret_cast<const int*>(CMSG_DATA(header));
        for (std::size_t index = 0; index < descriptorCount; ++index) {
            const int descriptor = descriptors[index];
            ++receivedCount;
            if (receivedCount == 1) {
                candidate = descriptor;
            } else if (descriptor >= 0) {
                close(descriptor);
            }
        }
    }
    const bool exactlyOne = shapeValid
        && receivedCount == 1
        && candidate >= 0
        && (message.msg_flags & MSG_CTRUNC) == 0;
    if (!exactlyOne && candidate >= 0) {
        close(candidate);
        candidate = -1;
    }
    *acceptedDescriptor = candidate;
    *valid = exactlyOne;
}

bool SendBufferDescriptor(int socketDescriptor, int bufferDescriptor) noexcept {
    BrokerHello hello{
        kBrokerProtocolMagic,
        kBrokerProtocolVersion,
        kMappingSize,
    };
    iovec payload{&hello, sizeof(hello)};
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &payload;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    cmsghdr* header = CMSG_FIRSTHDR(&message);
    if (header == nullptr) {
        return false;
    }
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    std::memcpy(CMSG_DATA(header), &bufferDescriptor, sizeof(bufferDescriptor));
    return sendmsg(socketDescriptor, &message, 0) == static_cast<ssize_t>(sizeof(hello));
}

}  // namespace

FDBrokerServer::~FDBrokerServer() {
    Stop();
}

bool FDBrokerServer::Start(const std::string& socketPath, uid_t allowedProducerUID) {
    Stop();
    if (!SafeSocketPath(socketPath)
        || allowedProducerUID == static_cast<uid_t>(-1)
        || allowedProducerUID == 0) {
        return false;
    }
    allowed_producer_uid_ = allowedProducerUID;
    ownership_lock_descriptor_ = AcquireOwnershipLock(socketPath);
    if (ownership_lock_descriptor_ < 0) {
        Stop();
        return false;
    }

    char bufferTemplate[] = "/tmp/cardputer-bridge-audio-buffer.XXXXXX";
    buffer_descriptor_ = mkstemp(bufferTemplate);
    if (buffer_descriptor_ < 0) {
        Stop();
        return false;
    }
    SetCloseOnExec(buffer_descriptor_);
    if (unlink(bufferTemplate) != 0
        || ftruncate(buffer_descriptor_, static_cast<off_t>(kMappingSize)) != 0) {
        Stop();
        return false;
    }
    buffer_ = Map(buffer_descriptor_);
    if (buffer_ == nullptr) {
        Stop();
        return false;
    }
    std::memset(buffer_, 0, kMappingSize);
    buffer_->magic = kSharedMemoryMagic;
    buffer_->version = kSharedMemoryVersion;
    buffer_->capacity_frames = kSharedMemoryCapacityFrames;

    if (!RemoveStaleOwnedSocket(socketPath)) {
        Stop();
        return false;
    }

    const int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
        Stop();
        return false;
    }
    SetCloseOnExec(listener);
    DisableSigPipe(listener);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, socketPath.c_str(), socketPath.size() + 1);
    if (bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
        close(listener);
        Stop();
        return false;
    }
    struct stat socketMetadata{};
    if (lstat(socketPath.c_str(), &socketMetadata) != 0
        || !S_ISSOCK(socketMetadata.st_mode)
        || socketMetadata.st_uid != geteuid()) {
        close(listener);
        Stop();
        return false;
    }
    const std::uint64_t socketDevice = static_cast<std::uint64_t>(socketMetadata.st_dev);
    const std::uint64_t socketInode = static_cast<std::uint64_t>(socketMetadata.st_ino);
    if (chmod(socketPath.c_str(), 0666) != 0 || listen(listener, 4) != 0) {
        close(listener);
        RemoveOwnedSocket(socketPath, socketDevice, socketInode);
        Stop();
        return false;
    }
    socket_path_ = socketPath;
    socket_device_ = socketDevice;
    socket_inode_ = socketInode;
    listener_descriptor_.store(listener, std::memory_order_release);
    running_.store(true, std::memory_order_release);
    try {
        worker_ = std::thread(&FDBrokerServer::Serve, this);
    } catch (...) {
        Stop();
        return false;
    }
    return true;
}

void FDBrokerServer::Stop() noexcept {
    running_.store(false, std::memory_order_release);
    const int client = client_descriptor_.exchange(-1, std::memory_order_acq_rel);
    if (client >= 0) {
        shutdown(client, SHUT_RDWR);
        close(client);
    }
    const int listener = listener_descriptor_.exchange(-1, std::memory_order_acq_rel);
    if (listener >= 0) {
        shutdown(listener, SHUT_RDWR);
        close(listener);
    }
    if (worker_.joinable()) {
        worker_.join();
    }
    Deactivate(buffer_);
    if (buffer_ != nullptr) {
        munmap(buffer_, kMappingSize);
        buffer_ = nullptr;
    }
    if (buffer_descriptor_ >= 0) {
        close(buffer_descriptor_);
        buffer_descriptor_ = -1;
    }
    if (!socket_path_.empty()) {
        RemoveOwnedSocket(socket_path_, socket_device_, socket_inode_);
    }
    socket_path_.clear();
    socket_device_ = 0;
    socket_inode_ = 0;
    if (ownership_lock_descriptor_ >= 0) {
        flock(ownership_lock_descriptor_, LOCK_UN);
        close(ownership_lock_descriptor_);
        ownership_lock_descriptor_ = -1;
    }
}

int FDBrokerServer::DuplicateBufferDescriptor() const noexcept {
    return buffer_descriptor_ < 0 ? -1 : dup(buffer_descriptor_);
}

std::uint64_t FDBrokerServer::rejected_peers() const noexcept {
    return rejected_peers_.load(std::memory_order_acquire);
}

void FDBrokerServer::Serve() noexcept {
    while (running_.load(std::memory_order_acquire)) {
        const int listener = listener_descriptor_.load(std::memory_order_acquire);
        if (listener < 0) {
            break;
        }
        const int client = accept(listener, nullptr, nullptr);
        if (client < 0) {
            if (!running_.load(std::memory_order_acquire)) {
                break;
            }
            continue;
        }
        SetCloseOnExec(client);
        DisableSigPipe(client);
        uid_t peerUID = static_cast<uid_t>(-1);
        gid_t peerGID = static_cast<gid_t>(-1);
        if (getpeereid(client, &peerUID, &peerGID) != 0
            || peerUID != allowed_producer_uid_) {
            rejected_peers_.fetch_add(1, std::memory_order_acq_rel);
            close(client);
            continue;
        }
        Deactivate(buffer_);
        client_descriptor_.store(client, std::memory_order_release);
        if (!SendBufferDescriptor(client, buffer_descriptor_)) {
            Deactivate(buffer_);
            if (client_descriptor_.exchange(-1, std::memory_order_acq_rel) == client) {
                close(client);
            }
            continue;
        }
        char byte = 0;
        while (running_.load(std::memory_order_acquire)
               && recv(client, &byte, sizeof(byte), 0) > 0) {
        }
        Deactivate(buffer_);
        if (client_descriptor_.exchange(-1, std::memory_order_acq_rel) == client) {
            close(client);
        }
    }
}

std::optional<uid_t> ConsoleUserUID() noexcept {
    struct stat metadata{};
    if (stat("/dev/console", &metadata) != 0
        || metadata.st_uid == 0
        || metadata.st_uid == static_cast<uid_t>(-1)) {
        return std::nullopt;
    }
    return metadata.st_uid;
}

std::optional<uid_t> ExpectedBrokerUID() noexcept {
    if (IsTestMode()) {
        const char* overrideValue = std::getenv(
            "CARDPUTER_BRIDGE_AUDIO_EXPECTED_BROKER_UID");
        if (overrideValue == nullptr) {
            return geteuid();
        }
        char* end = nullptr;
        errno = 0;
        const unsigned long parsed = std::strtoul(overrideValue, &end, 10);
        if (errno != 0
            || end == overrideValue
            || *end != '\0'
            || parsed > std::numeric_limits<uid_t>::max()) {
            return std::nullopt;
        }
        return static_cast<uid_t>(parsed);
    }
    passwd account{};
    passwd* result = nullptr;
    char storage[16384]{};
    if (getpwnam_r("_coreaudiod", &account, storage, sizeof(storage), &result) != 0
        || result == nullptr
        || account.pw_uid == 0
        || account.pw_uid == static_cast<uid_t>(-1)) {
        return std::nullopt;
    }
    return account.pw_uid;
}

const char* ResolveBrokerSocketPath() noexcept {
    if (!IsTestMode()) {
        return kBrokerSocketPath;
    }
    const char* candidate = std::getenv("CARDPUTER_BRIDGE_AUDIO_BROKER_SOCKET");
    if (candidate == nullptr) {
        return nullptr;
    }
    const std::string path(candidate);
    return SafeSocketPath(path) ? candidate : nullptr;
}

bool ConnectAndReceiveBuffer(
    const char* socketPath,
    uid_t expectedBrokerUID,
    int* outControlDescriptor,
    int* outBufferDescriptor) noexcept {
    if (socketPath == nullptr || outControlDescriptor == nullptr || outBufferDescriptor == nullptr) {
        return false;
    }
    *outControlDescriptor = -1;
    *outBufferDescriptor = -1;
    const std::string path(socketPath);
    if (!SafeSocketPath(path)) {
        return false;
    }
    const int controlDescriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (controlDescriptor < 0) {
        return false;
    }
    SetCloseOnExec(controlDescriptor);
    DisableSigPipe(controlDescriptor);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    if (connect(
            controlDescriptor,
            reinterpret_cast<const sockaddr*>(&address),
            sizeof(address)) != 0) {
        close(controlDescriptor);
        return false;
    }
    uid_t peerUID = static_cast<uid_t>(-1);
    gid_t peerGID = static_cast<gid_t>(-1);
    if (getpeereid(controlDescriptor, &peerUID, &peerGID) != 0
        || peerUID != expectedBrokerUID) {
        close(controlDescriptor);
        return false;
    }

    BrokerHello hello{};
    iovec payload{&hello, sizeof(hello)};
    const int descriptorLimit = getdtablesize();
    if (descriptorLimit <= 0 || descriptorLimit > 65536) {
        close(controlDescriptor);
        return false;
    }
    const std::size_t controlBytes = CMSG_SPACE(
        sizeof(int) * static_cast<std::size_t>(descriptorLimit));
    std::unique_ptr<char[]> control(new (std::nothrow) char[controlBytes]{});
    if (!control) {
        close(controlDescriptor);
        return false;
    }
    msghdr message{};
    message.msg_iov = &payload;
    message.msg_iovlen = 1;
    message.msg_control = control.get();
    message.msg_controllen = controlBytes;
    const ssize_t received = recvmsg(controlDescriptor, &message, MSG_WAITALL);
    int bufferDescriptor = -1;
    bool rightsValid = false;
    CloseReceivedRights(message, &bufferDescriptor, &rightsValid);
    if (received != static_cast<ssize_t>(sizeof(hello))
        || !rightsValid) {
        if (bufferDescriptor >= 0) {
            close(bufferDescriptor);
        }
        close(controlDescriptor);
        return false;
    }
    if (hello.magic != kBrokerProtocolMagic
        || hello.version != kBrokerProtocolVersion
        || hello.mapping_size != kMappingSize
        || bufferDescriptor < 0) {
        if (bufferDescriptor >= 0) {
            close(bufferDescriptor);
        }
        close(controlDescriptor);
        return false;
    }
    SetCloseOnExec(bufferDescriptor);
    *outControlDescriptor = controlDescriptor;
    *outBufferDescriptor = bufferDescriptor;
    return true;
}

}  // namespace cardputer_bridge::audio_ipc
