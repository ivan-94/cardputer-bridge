#include "AudioBridgeFDBroker.hpp"
#include "AudioBridgeSharedMemory.hpp"

#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {

using cardputer_bridge::audio_ipc::Consumer;
using cardputer_bridge::audio_ipc::FDBrokerServer;
using cardputer_bridge::audio_ipc::SharedAudioBuffer;

UInt32 Active(const SharedAudioBuffer* buffer) noexcept {
    return buffer == nullptr
        ? 0
        : __atomic_load_n(&buffer->producer_active, __ATOMIC_ACQUIRE);
}

std::uint64_t Generation(const SharedAudioBuffer* buffer) noexcept {
    return buffer == nullptr
        ? 0
        : __atomic_load_n(&buffer->producer_generation, __ATOMIC_ACQUIRE);
}

bool IsSilent(const std::array<Float32, 256>& samples) {
    return std::all_of(samples.begin(), samples.end(), [](Float32 sample) {
        return sample == 0.0F;
    });
}

void StoreTestSample(
    SharedAudioBuffer* buffer,
    std::uint64_t index,
    Float32 sample) noexcept {
    std::uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(sample));
    std::memcpy(&bits, &sample, sizeof(bits));
    __atomic_store_n(
        &buffer->sample_bits[
            index % cardputer_bridge::audio_ipc::kSharedMemoryCapacityFrames],
        bits,
        __ATOMIC_RELAXED);
}

void Append(
    std::vector<Float32>* capture,
    const Float32* samples,
    std::size_t count) {
    if (capture != nullptr) {
        capture->insert(capture->end(), samples, samples + count);
    }
}

bool WriteCapture(const std::string& path, const std::vector<Float32>& capture) {
    if (path.empty()) {
        return true;
    }
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) {
        return false;
    }
    const std::size_t written = std::fwrite(
        capture.data(),
        sizeof(Float32),
        capture.size(),
        file);
    return std::fclose(file) == 0 && written == capture.size();
}

bool WaitForPulse(
    Consumer& consumer,
    std::chrono::milliseconds timeout,
    std::vector<Float32>* capture = nullptr) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        std::array<Float32, 256> samples{};
        consumer.Render(samples.data(), static_cast<UInt32>(samples.size()));
        Append(capture, samples.data(), samples.size());
        const Float32 peak = *std::max_element(
            samples.begin(),
            samples.end(),
            [](Float32 left, Float32 right) {
                return std::abs(left) < std::abs(right);
            });
        if (std::abs(peak) >= 0.49F) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
}

int ConsumerFirst(const std::string& socketPath, const std::string& capturePath) {
    FDBrokerServer server;
    if (!server.Start(socketPath, getuid())) {
        std::fprintf(stderr, "FAIL broker start\n");
        return 1;
    }
    Consumer consumer;
    if (!consumer.AttachDescriptor(server.DuplicateBufferDescriptor())) {
        std::fprintf(stderr, "FAIL consumer attach\n");
        return 1;
    }
    std::array<Float32, 256> before;
    before.fill(0.75F);
    consumer.Render(before.data(), static_cast<UInt32>(before.size()));
    std::vector<Float32> capture;
    Append(&capture, before.data(), before.size());
    if (!IsSilent(before)) {
        std::fprintf(stderr, "FAIL consumer-first must begin silent\n");
        return 1;
    }
    std::printf("READY audio_fd_broker scenario=consumer-first\n");
    std::fflush(stdout);
    if (!WaitForPulse(consumer, std::chrono::seconds(2), &capture)) {
        std::fprintf(stderr, "FAIL broker pulse missing\n");
        return 1;
    }
    for (int chunk = 0; chunk < 40; ++chunk) {
        std::array<Float32, 256> samples{};
        consumer.Render(samples.data(), static_cast<UInt32>(samples.size()));
        Append(&capture, samples.data(), samples.size());
    }
    const auto stopDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (Active(server.buffer()) != 0
           && std::chrono::steady_clock::now() < stopDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::array<Float32, 256> after;
    after.fill(0.75F);
    consumer.Render(after.data(), static_cast<UInt32>(after.size()));
    Append(&capture, after.data(), after.size());
    if (Active(server.buffer()) != 0 || !IsSilent(after)) {
        std::fprintf(stderr, "FAIL broker stop must render silence\n");
        return 1;
    }
    if (!WriteCapture(capturePath, capture)) {
        std::fprintf(stderr, "FAIL unable to write broker PCM capture\n");
        return 1;
    }
    std::puts("PASS broker_consumer_first_pulse_and_stop");
    return 0;
}

int RejectCurrentUser(const std::string& socketPath) {
    FDBrokerServer server;
    if (!server.Start(socketPath, getuid() + 1)) {
        std::fprintf(stderr, "FAIL broker start\n");
        return 1;
    }
    std::printf("READY audio_fd_broker scenario=reject-current-user\n");
    std::fflush(stdout);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (server.rejected_peers() == 0
           && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (server.rejected_peers() == 0 || Active(server.buffer()) != 0) {
        std::fprintf(stderr, "FAIL unauthorized peer was not rejected fail-closed\n");
        return 1;
    }
    std::puts("PASS broker_rejects_unauthorized_peer");
    return 0;
}

int CrashRestart(const std::string& socketPath) {
    FDBrokerServer server;
    if (!server.Start(socketPath, getuid())) {
        std::fprintf(stderr, "FAIL broker start\n");
        return 1;
    }
    Consumer consumer;
    if (!consumer.AttachDescriptor(server.DuplicateBufferDescriptor())) {
        std::fprintf(stderr, "FAIL consumer attach\n");
        return 1;
    }
    std::printf("READY audio_fd_broker scenario=crash-restart\n");
    std::fflush(stdout);
    if (!WaitForPulse(consumer, std::chrono::seconds(2))) {
        std::fprintf(stderr, "FAIL first producer pulse missing\n");
        return 1;
    }
    const std::uint64_t firstGeneration = Generation(server.buffer());
    const auto crashDeadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(350);
    while (Active(server.buffer()) != 0
           && std::chrono::steady_clock::now() < crashDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if (Active(server.buffer()) != 0) {
        std::fprintf(stderr, "FAIL crashed producer did not fail closed within 350ms\n");
        return 1;
    }
    std::array<Float32, 256> afterCrash;
    afterCrash.fill(0.75F);
    consumer.Render(afterCrash.data(), static_cast<UInt32>(afterCrash.size()));
    if (!IsSilent(afterCrash)) {
        std::fprintf(stderr, "FAIL crashed producer left non-silent PCM\n");
        return 1;
    }
    if (!WaitForPulse(consumer, std::chrono::seconds(2))) {
        std::fprintf(stderr, "FAIL restarted producer pulse missing\n");
        return 1;
    }
    if (Generation(server.buffer()) <= firstGeneration) {
        std::fprintf(stderr, "FAIL producer generation did not advance\n");
        return 1;
    }
    const auto stopDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (Active(server.buffer()) != 0
           && std::chrono::steady_clock::now() < stopDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (Active(server.buffer()) != 0) {
        std::fprintf(stderr, "FAIL restarted producer did not stop\n");
        return 1;
    }
    std::puts("PASS broker_crash_fails_closed_and_restart_recovers");
    return 0;
}

int CorruptRing(const std::string& socketPath) {
    FDBrokerServer server;
    if (!server.Start(socketPath, getuid())) {
        std::fprintf(stderr, "FAIL broker start\n");
        return 1;
    }
    Consumer consumer;
    if (!consumer.AttachDescriptor(server.DuplicateBufferDescriptor())) {
        std::fprintf(stderr, "FAIL consumer attach\n");
        return 1;
    }
    SharedAudioBuffer* buffer = server.buffer();
    __atomic_store_n(&buffer->producer_active, 1U, __ATOMIC_RELEASE);
    __atomic_store_n(
        &buffer->lease_deadline_host_time,
        std::numeric_limits<std::uint64_t>::max(),
        __ATOMIC_RELEASE);

    std::array<Float32, 256> output;
    output.fill(0.75F);
    constexpr Float32 kStaleSample = -0.75F;
    constexpr Float32 kFreshSample = 0.25F;
    const std::uint64_t oversizedWrite =
        static_cast<std::uint64_t>(
            cardputer_bridge::audio_ipc::kSharedMemoryCapacityFrames)
        + 1;
    const std::uint64_t liveRead =
        oversizedWrite - cardputer_bridge::audio_ipc::kRealtimeCatchupFrames;
    for (std::uint64_t index = 0;
         index < cardputer_bridge::audio_ipc::kSharedMemoryCapacityFrames;
         ++index) {
        StoreTestSample(buffer, index, kStaleSample);
    }
    for (std::uint64_t index = liveRead; index < oversizedWrite; ++index) {
        StoreTestSample(buffer, index, kFreshSample);
    }
    __atomic_store_n(&buffer->read_index, 0ULL, __ATOMIC_RELEASE);
    __atomic_store_n(
        &buffer->write_index,
        oversizedWrite,
        __ATOMIC_RELEASE);
    const UInt32 caughtUp = consumer.Render(
        output.data(),
        static_cast<UInt32>(output.size()));
    if (caughtUp != output.size()
        || !std::all_of(output.begin(), output.end(), [](Float32 sample) {
            return sample == kFreshSample;
        })
        || __atomic_load_n(&buffer->read_index, __ATOMIC_ACQUIRE)
            != liveRead + output.size()) {
        std::fprintf(
            stderr,
            "FAIL oversized ring did not discard stale audio and rejoin live edge\n");
        return 1;
    }

    output.fill(0.75F);
    __atomic_store_n(&buffer->read_index, 2ULL, __ATOMIC_RELEASE);
    __atomic_store_n(&buffer->write_index, 1ULL, __ATOMIC_RELEASE);
    if (consumer.Render(output.data(), static_cast<UInt32>(output.size())) != 0
        || !IsSilent(output)) {
        std::fprintf(stderr, "FAIL reversed ring indices were not silent\n");
        return 1;
    }

    std::vector<Float32> oversized(
        cardputer_bridge::audio_ipc::kSharedMemoryCapacityFrames + 1,
        0.75F);
    if (consumer.Render(oversized.data(), static_cast<UInt32>(oversized.size())) != 0
        || std::any_of(oversized.begin(), oversized.end(), [](Float32 sample) {
            return sample != 0.0F;
        })) {
        std::fprintf(stderr, "FAIL oversized render request was not silent\n");
        return 1;
    }
    std::printf("READY audio_fd_broker scenario=corrupt-ring\n");
    std::puts("PASS broker_corrupt_ring_fails_silent");
    return 0;
}

int CountOpenDescriptors() noexcept {
    int count = 0;
    const int limit = getdtablesize();
    for (int descriptor = 0; descriptor < limit; ++descriptor) {
        if (fcntl(descriptor, F_GETFD) >= 0) {
            ++count;
        }
    }
    return count;
}

bool RejectMalformedRightsOnce(
    const std::string& socketPath,
    std::size_t descriptorCount,
    bool corruptHello,
    bool shortPayload = false) {
    unlink(socketPath.c_str());
    const int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
        return false;
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, socketPath.c_str(), socketPath.size() + 1);
    if (bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0
        || listen(listener, 1) != 0) {
        close(listener);
        unlink(socketPath.c_str());
        return false;
    }

    bool sent = false;
    std::thread sender([&]() {
        const int client = accept(listener, nullptr, nullptr);
        if (client < 0) {
            return;
        }
        cardputer_bridge::audio_ipc::BrokerHello hello{
            corruptHello ? 0U : cardputer_bridge::audio_ipc::kBrokerProtocolMagic,
            cardputer_bridge::audio_ipc::kBrokerProtocolVersion,
            sizeof(SharedAudioBuffer),
        };
        iovec payload{&hello, sizeof(hello)};
        if (shortPayload) {
            payload.iov_len = sizeof(hello) - 1;
        }
        alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int) * 12)]{};
        std::array<int, 12> descriptors{};
        descriptors.fill(-1);
        bool opened = descriptorCount <= descriptors.size();
        for (std::size_t index = 0; opened && index < descriptorCount; ++index) {
            descriptors[index] = open("/dev/null", O_RDONLY);
            opened = descriptors[index] >= 0;
        }
        if (opened) {
            msghdr message{};
            message.msg_iov = &payload;
            message.msg_iovlen = 1;
            message.msg_control = control;
            message.msg_controllen = CMSG_SPACE(sizeof(int) * descriptorCount);
            cmsghdr* header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET;
            header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = CMSG_LEN(sizeof(int) * descriptorCount);
            std::memcpy(
                CMSG_DATA(header),
                descriptors.data(),
                sizeof(int) * descriptorCount);
            sent = sendmsg(client, &message, 0)
                == static_cast<ssize_t>(payload.iov_len);
        }
        for (std::size_t index = 0; index < descriptorCount; ++index) {
            if (descriptors[index] >= 0) {
                close(descriptors[index]);
            }
        }
        close(client);
    });
    int controlDescriptor = -1;
    int bufferDescriptor = -1;
    const bool accepted = cardputer_bridge::audio_ipc::ConnectAndReceiveBuffer(
        socketPath.c_str(),
        getuid(),
        &controlDescriptor,
        &bufferDescriptor);
    if (controlDescriptor >= 0) {
        close(controlDescriptor);
    }
    if (bufferDescriptor >= 0) {
        close(bufferDescriptor);
    }
    sender.join();
    close(listener);
    unlink(socketPath.c_str());
    return sent && !accepted;
}

int MalformedRights(const std::string& socketPath) {
    const int baseline = CountOpenDescriptors();
    for (int iteration = 0; iteration < 32; ++iteration) {
        if (!RejectMalformedRightsOnce(socketPath, 1, true)
            || !RejectMalformedRightsOnce(socketPath, 1, false, true)
            || !RejectMalformedRightsOnce(socketPath, 2, false)
            || !RejectMalformedRightsOnce(socketPath, 12, false)) {
            std::fprintf(stderr, "FAIL malformed SCM_RIGHTS was not rejected\n");
            return 1;
        }
    }
    const int finalCount = CountOpenDescriptors();
    if (finalCount != baseline) {
        std::fprintf(
            stderr,
            "FAIL malformed SCM_RIGHTS leaked descriptors baseline=%d final=%d\n",
            baseline,
            finalCount);
        return 1;
    }
    std::printf("READY audio_fd_broker scenario=malformed-rights\n");
    std::puts("PASS broker_malformed_rights_rejected_without_fd_leak");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if ((argc != 5 && argc != 7)
        || std::strcmp(argv[1], "--socket") != 0
        || std::strcmp(argv[3], "--scenario") != 0
        || (argc == 7 && std::strcmp(argv[5], "--capture") != 0)) {
        std::fprintf(
            stderr,
            "usage: audio_broker_test_server --socket <path> --scenario consumer-first\n");
        return 64;
    }
    const std::string scenario = argv[4];
    if (scenario == "consumer-first") {
        return ConsumerFirst(argv[2], argc == 7 ? argv[6] : "");
    }
    if (scenario == "reject-current-user") {
        return RejectCurrentUser(argv[2]);
    }
    if (scenario == "crash-restart") {
        return CrashRestart(argv[2]);
    }
    if (scenario == "corrupt-ring") {
        return CorruptRing(argv[2]);
    }
    if (scenario == "malformed-rights") {
        return MalformedRights(argv[2]);
    }
    std::fprintf(stderr, "unknown scenario: %s\n", scenario.c_str());
    return 64;
}
