#include "audio_frame_ring.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

cardbridge::CapturedAudioFrame frame(std::uint32_t sequence) {
    cardbridge::CapturedAudioFrame value{};
    value.sequence = sequence;
    value.capture_sample_index = sequence * cardbridge::kAudioFrameSamples;
    value.samples.fill(static_cast<std::int16_t>(sequence));
    return value;
}

void test_preserves_capture_order_without_allocation() {
    cardbridge::AudioFrameRing<3> ring;
    require(ring.try_push(frame(7)), "first frame should fit");
    require(ring.try_push(frame(8)), "second frame should fit");

    cardbridge::CapturedAudioFrame output{};
    require(ring.try_pop(output), "first frame should be available");
    require(output.sequence == 7 && output.samples.front() == 7,
            "first frame must retain capture metadata and samples");
    require(ring.try_pop(output), "second frame should be available");
    require(output.sequence == 8, "ring must preserve SPSC order");
    require(!ring.try_pop(output), "empty ring must not fabricate audio");
}

void test_bounds_latency_instead_of_blocking_capture() {
    cardbridge::AudioFrameRing<2> ring;
    require(ring.try_push(frame(1)), "first bounded frame should fit");
    require(ring.try_push(frame(2)), "second bounded frame should fit");
    require(!ring.try_push(frame(3)), "full ring must refuse without blocking");
    require(ring.size() == 2, "full ring must retain its fixed bound");
}

}  // namespace

int main() {
    test_preserves_capture_order_without_allocation();
    test_bounds_latency_instead_of_blocking_capture();
    std::cout << "PASS audio_frame_ring_preserves_order_and_bounds_latency\n";
    return EXIT_SUCCESS;
}
