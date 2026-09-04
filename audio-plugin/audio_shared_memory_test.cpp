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

    // A recorder may attach after the live producer has already primed the
    // ring. Preserve that recent, leased audio as bounded pre-roll; otherwise
    // Attach() discards the jitter reservoir and the first ordinary Wi-Fi
    // scheduling pause becomes audible silence.
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
        if (std::abs(output[index] - stale[index]) > 0.000001F) {
            std::fprintf(stderr, "FAIL late consumer discarded leased pre-roll at %u\n", index);
            return 1;
        }
    }

    // Keep a 1.28-second playout reservoir when backlog passes 1.32 seconds.
    // A packet capture on the real LAN observed a 1.143-second ingress pause
    // followed by complete delivery, so a shorter reservoir cannot preserve
    // voice continuity without changing the physical transport.
    for (UInt32 chunk = 0; chunk < 67; ++chunk) {
        std::fill_n(stale, 960, static_cast<Float32>(chunk) / 1000.0F);
        if (!producer.WriteFloat32(stale, 960)) {
            std::fprintf(stderr, "FAIL active-consumer backlog staging\n");
            return 1;
        }
    }
    std::fill_n(output, 960, 0.0F);
    if (consumer.Render(output, 960) != 960) {
        std::fprintf(stderr, "FAIL active-consumer reservoir render count\n");
        return 1;
    }
    for (UInt32 index = 0; index < 960; ++index) {
        if (std::abs(output[index] - 0.003F) > 0.000001F) {
            std::fprintf(stderr, "FAIL active consumer did not retain 1.28 s reservoir at %u\n", index);
            return 1;
        }
    }

    // The producer lease is a crash fail-safe, not the network jitter budget.
    // A valid reservoir must remain readable through an ingress pause longer
    // than the former 200 ms lease; otherwise the driver replaces buffered
    // speech with digital silence even though no audio has been lost.
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    std::fill_n(output, 960, 0.0F);
    if (consumer.Render(output, 960) != 960) {
        std::fprintf(stderr, "FAIL leased reservoir expired during network pause\n");
        return 1;
    }
    for (UInt32 index = 0; index < 960; ++index) {
        if (std::abs(output[index] - 0.004F) > 0.000001F) {
            std::fprintf(stderr, "FAIL leased reservoir was silenced at %u\n", index);
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
