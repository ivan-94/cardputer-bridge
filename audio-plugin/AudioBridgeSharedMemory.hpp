#pragma once

#include <CoreAudio/CoreAudioTypes.h>

#include <cstdint>

namespace cardputer_bridge::audio_ipc {

constexpr const char* kSharedMemoryName = "/cardputer_bridge_audio_v3";
constexpr UInt32 kSharedMemoryMagic = 0x43424131;
constexpr UInt32 kSharedMemoryVersion = 3;
constexpr UInt32 kSharedMemoryCapacityFrames = 65536;
// Capacity protects against scheduling stalls; it must never become an audio
// delay line. A live input may retain at most 100 ms and catches up to the
// newest 20 ms when that bound is crossed.
constexpr UInt32 kMaximumRealtimeBacklogFrames = 4800;
constexpr UInt32 kRealtimeCatchupFrames = 960;
constexpr UInt32 kTestPulseFrames = 4800;
constexpr UInt32 kProducerLeaseMilliseconds = 200;

struct alignas(64) SharedAudioBuffer {
    UInt32 magic;
    UInt32 version;
    UInt32 capacity_frames;
    UInt32 reserved;
    alignas(64) std::uint64_t write_index;
    alignas(64) std::uint64_t read_index;
    alignas(64) std::uint64_t producer_generation;
    alignas(64) std::uint64_t lease_deadline_host_time;
    alignas(64) UInt32 producer_active;
    // Cross-process sample slots use atomic bit loads/stores. write_index is
    // producer-owned and read_index is consumer-owned; neither side rewrites
    // the other side's cursor.
    alignas(64) std::uint32_t sample_bits[kSharedMemoryCapacityFrames];
};

class Consumer {
public:
    Consumer() = default;
    Consumer(const Consumer&) = delete;
    Consumer& operator=(const Consumer&) = delete;
    ~Consumer();

    bool Attach();
    bool AttachDescriptor(int descriptor);
    void Detach();
    UInt32 Render(Float32* output, UInt32 frames) noexcept;

private:
    int descriptor_{-1};
    SharedAudioBuffer* buffer_{nullptr};
};

class Producer {
public:
    Producer() = default;
    Producer(const Producer&) = delete;
    Producer& operator=(const Producer&) = delete;
    ~Producer();

    bool OpenOrCreate();
    bool OpenBroker(const char* socketPath);
    bool WriteCountingPulse(UInt32 frames);
    bool WriteFloat32(const Float32* samples, UInt32 frames);
    bool WritePCM16Upsampled3x(const std::uint8_t* pcm16LE, UInt32 byteCount);
    bool RefreshLease(UInt32 milliseconds = kProducerLeaseMilliseconds) noexcept;
    std::uint64_t ConsumedFrames() const noexcept;
    void Stop() noexcept;
    void Close() noexcept;

private:
    int descriptor_{-1};
    int control_descriptor_{-1};
    SharedAudioBuffer* buffer_{nullptr};
};

bool DestroyTestObject() noexcept;

}  // namespace cardputer_bridge::audio_ipc
