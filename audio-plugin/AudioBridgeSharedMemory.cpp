#include "AudioBridgeSharedMemory.hpp"
#include "AudioBridgeFDBroker.hpp"

#include <fcntl.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>

namespace cardputer_bridge::audio_ipc {
namespace {

constexpr std::size_t kMappingSize = sizeof(SharedAudioBuffer);

bool IsTestMode() noexcept {
    const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
    return testMode != nullptr && std::strcmp(testMode, "1") == 0;
}

const char* ResolveSharedMemoryName() noexcept {
    if (!IsTestMode()) {
        return kSharedMemoryName;
    }
    const char* candidate = std::getenv("CARDPUTER_BRIDGE_AUDIO_SHM_NAME");
    constexpr const char* prefix = "/cardputer_bridge_test_";
    if (candidate == nullptr || std::strncmp(candidate, prefix, std::strlen(prefix)) != 0
        || std::strlen(candidate) >= 120) {
        return nullptr;
    }
    for (const char* character = candidate + std::strlen(prefix);
         *character != '\0';
         ++character) {
        const bool safe = (*character >= 'a' && *character <= 'z')
            || (*character >= 'A' && *character <= 'Z')
            || (*character >= '0' && *character <= '9')
            || *character == '_'
            || *character == '-';
        if (!safe) {
            return nullptr;
        }
    }
    return candidate;
}

std::uint64_t HostTicksAfterMilliseconds(UInt32 milliseconds) noexcept {
    mach_timebase_info_data_t timebase{};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) {
        return 0;
    }
    const long double nanoseconds = static_cast<long double>(milliseconds) * 1'000'000.0L;
    const long double ticks = nanoseconds
        * static_cast<long double>(timebase.denom)
        / static_cast<long double>(timebase.numer);
    return mach_absolute_time() + static_cast<std::uint64_t>(ticks);
}

void StoreRelease(UInt32* destination, UInt32 value) noexcept {
    __atomic_store_n(destination, value, __ATOMIC_RELEASE);
}

void StoreRelease(std::uint64_t* destination, std::uint64_t value) noexcept {
    __atomic_store_n(destination, value, __ATOMIC_RELEASE);
}

UInt32 LoadAcquire(const UInt32* source) noexcept {
    return __atomic_load_n(source, __ATOMIC_ACQUIRE);
}

std::uint64_t LoadAcquire(const std::uint64_t* source) noexcept {
    return __atomic_load_n(source, __ATOMIC_ACQUIRE);
}

void StoreSample(SharedAudioBuffer* buffer, std::uint64_t index, Float32 sample) noexcept {
    std::uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(sample));
    std::memcpy(&bits, &sample, sizeof(bits));
    __atomic_store_n(
        &buffer->sample_bits[index % kSharedMemoryCapacityFrames],
        bits,
        __ATOMIC_RELAXED);
}

Float32 LoadSample(const SharedAudioBuffer* buffer, std::uint64_t index) noexcept {
    const std::uint32_t bits = __atomic_load_n(
        &buffer->sample_bits[index % kSharedMemoryCapacityFrames],
        __ATOMIC_RELAXED);
    Float32 sample = 0;
    std::memcpy(&sample, &bits, sizeof(sample));
    return sample;
}

SharedAudioBuffer* Map(int descriptor) {
    void* mapping = mmap(
        nullptr,
        kMappingSize,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0);
    return mapping == MAP_FAILED
        ? nullptr
        : static_cast<SharedAudioBuffer*>(mapping);
}

void Unmap(SharedAudioBuffer*& buffer) noexcept {
    if (buffer != nullptr) {
        munmap(buffer, kMappingSize);
        buffer = nullptr;
    }
}

void CloseDescriptor(int& descriptor) noexcept {
    if (descriptor >= 0) {
        close(descriptor);
        descriptor = -1;
    }
}

}  // namespace

Consumer::~Consumer() {
    Detach();
}

bool Consumer::Attach() {
    Detach();
    if (!IsTestMode()) {
        return false;
    }
    const char* name = ResolveSharedMemoryName();
    if (name == nullptr) {
        return false;
    }
    const int descriptor = shm_open(name, O_RDWR, 0);
    if (descriptor < 0) {
        return false;
    }
    return AttachDescriptor(descriptor);
}

bool Consumer::AttachDescriptor(int descriptor) {
    Detach();
    if (descriptor < 0) {
        return false;
    }
    descriptor_ = descriptor;
    buffer_ = Map(descriptor_);
    if (buffer_ == nullptr
        || buffer_->magic != kSharedMemoryMagic
        || buffer_->version != kSharedMemoryVersion
        || buffer_->capacity_frames != kSharedMemoryCapacityFrames) {
        Detach();
        return false;
    }
    // StartIO represents a new real-time listener, not a request to replay
    // everything produced while no client was attached. Join at the live edge
    // so the 1.36-second safety capacity cannot become user-visible latency.
    StoreRelease(&buffer_->read_index, LoadAcquire(&buffer_->write_index));
    return true;
}

void Consumer::Detach() {
    Unmap(buffer_);
    CloseDescriptor(descriptor_);
}

UInt32 Consumer::Render(Float32* output, UInt32 frames) noexcept {
    if (output == nullptr) {
        return 0;
    }
    std::memset(output, 0, static_cast<std::size_t>(frames) * sizeof(Float32));
    if (frames > kSharedMemoryCapacityFrames
        || buffer_ == nullptr
        || LoadAcquire(&buffer_->producer_active) == 0) {
        return 0;
    }
    const std::uint64_t leaseDeadline = LoadAcquire(
        &buffer_->lease_deadline_host_time);
    if (leaseDeadline == 0 || mach_absolute_time() > leaseDeadline) {
        return 0;
    }

    const std::uint64_t write = LoadAcquire(&buffer_->write_index);
    std::uint64_t read = LoadAcquire(&buffer_->read_index);
    if (write < read) {
        return 0;
    }
    if (write - read > kMaximumRealtimeBacklogFrames) {
        const std::uint64_t liveRead = write > kRealtimeCatchupFrames
            ? write - kRealtimeCatchupFrames
            : 0;
        while (read < liveRead
               && !__atomic_compare_exchange_n(
                   &buffer_->read_index,
                   &read,
                   liveRead,
                   true,
                   __ATOMIC_ACQ_REL,
                   __ATOMIC_ACQUIRE)) {
        }
        read = std::max(read, liveRead);
    }
    if (read > write) {
        return 0;
    }
    const std::uint64_t available = write - read;
    const UInt32 count = static_cast<UInt32>(std::min<std::uint64_t>(available, frames));
    if (count == 0) {
        return 0;
    }
    for (UInt32 index = 0; index < count; ++index) {
        output[index] = LoadSample(buffer_, read + index);
    }
    const std::uint64_t latestWrite = LoadAcquire(&buffer_->write_index);
    if (latestWrite < read || latestWrite - read > kSharedMemoryCapacityFrames) {
        // The render callback was stalled long enough for the producer to
        // wrap while we copied. Discard the ambiguous block and rejoin live.
        std::memset(output, 0, static_cast<std::size_t>(frames) * sizeof(Float32));
        const std::uint64_t liveRead = latestWrite > kRealtimeCatchupFrames
            ? latestWrite - kRealtimeCatchupFrames
            : 0;
        StoreRelease(&buffer_->read_index, liveRead);
        return 0;
    }
    StoreRelease(&buffer_->read_index, read + count);
    return count;
}

Producer::~Producer() {
    Close();
}

bool Producer::OpenOrCreate() {
    Close();
    if (!IsTestMode()) {
        return false;
    }
    const char* name = ResolveSharedMemoryName();
    if (name == nullptr) {
        return false;
    }
    descriptor_ = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    const bool created = descriptor_ >= 0;
    if (!created && errno == EEXIST) {
        descriptor_ = shm_open(name, O_RDWR, 0);
    }
    if (descriptor_ < 0) {
        return false;
    }
    if (created && ftruncate(descriptor_, kMappingSize) != 0) {
        Close();
        return false;
    }
    struct stat metadata{};
    if (fstat(descriptor_, &metadata) != 0
        || metadata.st_size < static_cast<off_t>(kMappingSize)) {
        Close();
        return false;
    }
    buffer_ = Map(descriptor_);
    if (buffer_ == nullptr) {
        Close();
        return false;
    }
    if (created) {
        std::memset(buffer_, 0, kMappingSize);
        buffer_->magic = kSharedMemoryMagic;
        buffer_->version = kSharedMemoryVersion;
        buffer_->capacity_frames = kSharedMemoryCapacityFrames;
    } else if (buffer_->magic != kSharedMemoryMagic
               || buffer_->version != kSharedMemoryVersion
               || buffer_->capacity_frames != kSharedMemoryCapacityFrames) {
        Close();
        return false;
    }
    Stop();
    const std::uint64_t generation = LoadAcquire(&buffer_->producer_generation);
    StoreRelease(&buffer_->producer_generation, generation + 1);
    return true;
}

bool Producer::OpenBroker(const char* socketPath) {
    Close();
    const std::optional<uid_t> expectedBrokerUID = ExpectedBrokerUID();
    if (!expectedBrokerUID.has_value()) {
        return false;
    }
    int controlDescriptor = -1;
    int bufferDescriptor = -1;
    if (!ConnectAndReceiveBuffer(
            socketPath,
            *expectedBrokerUID,
            &controlDescriptor,
            &bufferDescriptor)) {
        return false;
    }
    control_descriptor_ = controlDescriptor;
    descriptor_ = bufferDescriptor;
    buffer_ = Map(descriptor_);
    if (buffer_ == nullptr
        || buffer_->magic != kSharedMemoryMagic
        || buffer_->version != kSharedMemoryVersion
        || buffer_->capacity_frames != kSharedMemoryCapacityFrames) {
        Close();
        return false;
    }
    Stop();
    const std::uint64_t generation = LoadAcquire(&buffer_->producer_generation);
    StoreRelease(&buffer_->producer_generation, generation + 1);
    return true;
}

bool Producer::WriteCountingPulse(UInt32 frames) {
    if (buffer_ == nullptr || frames == 0 || frames > kSharedMemoryCapacityFrames) {
        return false;
    }
    const std::uint64_t write = LoadAcquire(&buffer_->write_index);
    for (UInt32 index = 0; index < frames; ++index) {
        const UInt32 block = index / 240;
        StoreSample(buffer_, write + index, block % 2 == 0 ? 0.5F : -0.5F);
    }
    StoreRelease(&buffer_->write_index, write + frames);
    if (!RefreshLease()) {
        return false;
    }
    StoreRelease(&buffer_->producer_active, 1);
    return true;
}

bool Producer::WriteFloat32(const Float32* samples, UInt32 frames) {
    if (buffer_ == nullptr || samples == nullptr || frames == 0
        || frames > kSharedMemoryCapacityFrames) {
        return false;
    }
    const std::uint64_t write = LoadAcquire(&buffer_->write_index);
    for (UInt32 index = 0; index < frames; ++index) {
        StoreSample(buffer_, write + index, samples[index]);
    }
    StoreRelease(&buffer_->write_index, write + frames);
    if (!RefreshLease()) {
        return false;
    }
    StoreRelease(&buffer_->producer_active, 1);
    return true;
}

bool Producer::WritePCM16Upsampled3x(
    const std::uint8_t* pcm16LE,
    UInt32 byteCount) {
    if (buffer_ == nullptr
        || pcm16LE == nullptr
        || byteCount == 0
        || byteCount % 2 != 0) {
        return false;
    }
    const UInt32 sourceFrames = byteCount / 2;
    const UInt32 outputFrames = sourceFrames * 3;
    if (sourceFrames > kSharedMemoryCapacityFrames / 3) {
        return false;
    }

    const std::uint64_t write = LoadAcquire(&buffer_->write_index);
    for (UInt32 sourceIndex = 0; sourceIndex < sourceFrames; ++sourceIndex) {
        const UInt32 byteIndex = sourceIndex * 2;
        const std::uint16_t bits = static_cast<std::uint16_t>(pcm16LE[byteIndex])
            | (static_cast<std::uint16_t>(pcm16LE[byteIndex + 1]) << 8);
        const Float32 sample = static_cast<Float32>(
            static_cast<std::int16_t>(bits)) / 32768.0F;
        const std::uint64_t outputIndex = write + sourceIndex * 3;
        for (UInt32 repeat = 0; repeat < 3; ++repeat) {
            StoreSample(buffer_, outputIndex + repeat, sample);
        }
    }
    StoreRelease(&buffer_->write_index, write + outputFrames);
    if (!RefreshLease()) {
        return false;
    }
    StoreRelease(&buffer_->producer_active, 1);
    return true;
}

bool Producer::RefreshLease(UInt32 milliseconds) noexcept {
    if (buffer_ == nullptr || milliseconds == 0) {
        return false;
    }
    const std::uint64_t deadline = HostTicksAfterMilliseconds(milliseconds);
    if (deadline == 0) {
        return false;
    }
    StoreRelease(&buffer_->lease_deadline_host_time, deadline);
    return true;
}

std::uint64_t Producer::ConsumedFrames() const noexcept {
    return buffer_ == nullptr ? 0 : LoadAcquire(&buffer_->read_index);
}

void Producer::Stop() noexcept {
    if (buffer_ != nullptr) {
        StoreRelease(&buffer_->producer_active, 0);
        StoreRelease(&buffer_->lease_deadline_host_time, 0);
    }
}

void Producer::Close() noexcept {
    Stop();
    Unmap(buffer_);
    CloseDescriptor(descriptor_);
    CloseDescriptor(control_descriptor_);
}

bool DestroyTestObject() noexcept {
    if (!IsTestMode()) {
        return false;
    }
    const char* name = ResolveSharedMemoryName();
    return name != nullptr && (shm_unlink(name) == 0 || errno == ENOENT);
}

}  // namespace cardputer_bridge::audio_ipc
