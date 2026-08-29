#include "AudioBridgeSharedMemory.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <unistd.h>

int main() {
    char name[96]{};
    std::snprintf(
        name,
        sizeof(name),
        "/cardputer_bridge_test_f%d",
        static_cast<int>(getpid()));
    setenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE", "1", 1);
    setenv("CARDPUTER_BRIDGE_AUDIO_SHM_NAME", name, 1);
    using namespace cardputer_bridge::audio_ipc;
    (void)DestroyTestObject();

    Producer producer;
    Consumer consumer;
    if (!producer.OpenOrCreate() || !consumer.Attach()) {
        std::fprintf(stderr, "FAIL unable to open isolated audio ring\n");
        return 1;
    }
    Float32 input[960]{};
    for (UInt32 index = 0; index < 960; ++index) {
        input[index] = static_cast<Float32>(index) / 1920.0F;
    }
    if (!producer.WriteFloat32(input, 960)) {
        std::fprintf(stderr, "FAIL float producer write\n");
        return 1;
    }
    Float32 output[960]{};
    if (consumer.Render(output, 960) != 960) {
        std::fprintf(stderr, "FAIL float consumer frame count\n");
        return 1;
    }
    for (UInt32 index = 0; index < 960; ++index) {
        if (std::abs(output[index] - input[index]) > 0.000001F) {
            std::fprintf(stderr, "FAIL float sample mismatch at %u\n", index);
            return 1;
        }
    }

    // A recorder may connect long after the producer started. It must begin
    // at the live edge instead of replaying stale audio accumulated before
    // StartIO attached the consumer.
    consumer.Detach();
    Float32 stale[960]{};
    std::fill_n(stale, 960, -0.75F);
    if (!producer.WriteFloat32(stale, 960) || !consumer.Attach()) {
        std::fprintf(stderr, "FAIL unable to stage late-consumer backlog\n");
        return 1;
    }
    Float32 fresh[960]{};
    std::fill_n(fresh, 960, 0.25F);
    if (!producer.WriteFloat32(fresh, 960)) {
        std::fprintf(stderr, "FAIL late-consumer fresh write\n");
        return 1;
    }
    std::fill_n(output, 960, 0.0F);
    if (consumer.Render(output, 960) != 960) {
        std::fprintf(stderr, "FAIL late-consumer render count\n");
        return 1;
    }
    for (UInt32 index = 0; index < 960; ++index) {
        if (std::abs(output[index] - fresh[index]) > 0.000001F) {
            std::fprintf(stderr, "FAIL late consumer replayed stale audio at %u\n", index);
            return 1;
        }
    }

    // Core Audio can keep a device started while no client callback is
    // actually draining it. Even without another Attach call, a real-time
    // render must shed an old backlog instead of adding more than a second of
    // latency to the next recorder.
    std::fill_n(stale, 960, -0.75F);
    for (UInt32 chunk = 0; chunk < 7; ++chunk) {
        if (!producer.WriteFloat32(stale, 960)) {
            std::fprintf(stderr, "FAIL active-consumer backlog staging\n");
            return 1;
        }
    }
    std::fill_n(fresh, 960, 0.25F);
    if (!producer.WriteFloat32(fresh, 960)) {
        std::fprintf(stderr, "FAIL active-consumer live-edge write\n");
        return 1;
    }
    std::fill_n(output, 960, 0.0F);
    if (consumer.Render(output, 960) != 960) {
        std::fprintf(stderr, "FAIL active-consumer live-edge render count\n");
        return 1;
    }
    for (UInt32 index = 0; index < 960; ++index) {
        if (std::abs(output[index] - fresh[index]) > 0.000001F) {
            std::fprintf(stderr, "FAIL active consumer retained stale backlog at %u\n", index);
            return 1;
        }
    }

    // Stress cursor ownership under a producer that outruns the renderer.
    // read_index must remain monotonic, and atomic sample slots must never
    // expose torn/non-finite Float32 values while the ring wraps.
    consumer.Detach();
    if (!consumer.Attach()) {
        std::fprintf(stderr, "FAIL concurrent consumer attach\n");
        return 1;
    }
    std::atomic<bool> writerDone{false};
    std::atomic<bool> concurrentFailure{false};
    std::thread reader([&] {
        Float32 concurrentOutput[256]{};
        std::uint64_t previousRead = producer.ConsumedFrames();
        UInt32 tailReads = 0;
        while (!writerDone.load(std::memory_order_acquire) || tailReads < 32) {
            consumer.Render(concurrentOutput, 256);
            const std::uint64_t currentRead = producer.ConsumedFrames();
            if (currentRead < previousRead) {
                concurrentFailure.store(true, std::memory_order_release);
            }
            previousRead = currentRead;
            for (const Float32 sample : concurrentOutput) {
                if (!std::isfinite(sample) || std::abs(sample) > 0.251F) {
                    concurrentFailure.store(true, std::memory_order_release);
                }
            }
            if (writerDone.load(std::memory_order_acquire)) {
                ++tailReads;
            }
        }
    });
    Float32 concurrentInput[320]{};
    for (UInt32 chunk = 0; chunk < 4096; ++chunk) {
        std::fill_n(
            concurrentInput,
            320,
            chunk % 2 == 0 ? 0.25F : -0.25F);
        if (!producer.WriteFloat32(concurrentInput, 320)) {
            concurrentFailure.store(true, std::memory_order_release);
            break;
        }
    }
    writerDone.store(true, std::memory_order_release);
    reader.join();
    if (concurrentFailure.load(std::memory_order_acquire)) {
        std::fprintf(stderr, "FAIL concurrent ring cursor/sample invariant\n");
        return 1;
    }
    producer.Stop();
    consumer.Detach();
    (void)DestroyTestObject();
    std::puts("PASS audio_float32_shared_ring");
    return 0;
}
