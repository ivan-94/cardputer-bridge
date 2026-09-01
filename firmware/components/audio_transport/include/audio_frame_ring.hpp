#pragma once

#include "audio_packet.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace cardbridge {

struct CapturedAudioFrame {
    std::array<std::int16_t, kAudioFrameSamples> samples{};
    std::uint32_t offer_generation = 0;
    std::uint32_t sequence = 0;
    std::uint32_t capture_sample_index = 0;
};

/// Fixed-capacity, allocation-free single-producer/single-consumer ring.
/// Capture never waits for the network: a full ring is reported immediately
/// so the caller can count the dropped frame and preserve a bounded latency.
template <std::size_t Capacity>
class AudioFrameRing {
    static_assert(Capacity > 0);

public:
    bool try_push(const CapturedAudioFrame& frame) {
        const auto head = head_.load(std::memory_order_relaxed);
        const auto tail = tail_.load(std::memory_order_acquire);
        if (head - tail >= Capacity) return false;
        frames_[head % Capacity] = frame;
        head_.store(head + 1, std::memory_order_release);
        return true;
    }

    bool try_pop(CapturedAudioFrame& frame) {
        const auto tail = tail_.load(std::memory_order_relaxed);
        const auto head = head_.load(std::memory_order_acquire);
        if (tail == head) return false;
        frame = frames_[tail % Capacity];
        tail_.store(tail + 1, std::memory_order_release);
        return true;
    }

    std::size_t size() const {
        const auto head = head_.load(std::memory_order_acquire);
        const auto tail = tail_.load(std::memory_order_acquire);
        return head - tail;
    }

    void clear() {
        const auto head = head_.load(std::memory_order_acquire);
        tail_.store(head, std::memory_order_release);
    }

private:
    std::array<CapturedAudioFrame, Capacity> frames_{};
    alignas(64) std::atomic_size_t head_{0};
    alignas(64) std::atomic_size_t tail_{0};
};

}  // namespace cardbridge
