#include "AudioBridgeSharedMemory.hpp"
#include "AudioBridgeFDBroker.hpp"

#include <array>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <thread>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: audio_test_producer --test-pulse|--test-crash-pulse|--broker-test-pulse|--broker-test-crash-pulse|--cleanup-test-ipc|--ff1-pulse\n");
        return 64;
    }
    if (std::strcmp(argv[1], "--cleanup-test-ipc") == 0) {
        return cardputer_bridge::audio_ipc::DestroyTestObject() ? 0 : 1;
    }
    UInt32 frames = 0;
    std::chrono::milliseconds activeDuration{0};
    std::chrono::milliseconds lingerDuration{0};
    bool crashWithoutCleanup = false;
    bool useBroker = false;
    bool waitForConsumer = false;
    if (std::strcmp(argv[1], "--test-pulse") == 0) {
        const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
        if (testMode == nullptr || std::strcmp(testMode, "1") != 0) {
            std::fprintf(stderr, "FAIL --test-pulse requires isolated test mode\n");
            return 1;
        }
        frames = cardputer_bridge::audio_ipc::kTestPulseFrames * 2;
        activeDuration = std::chrono::milliseconds(300);
        lingerDuration = std::chrono::milliseconds(500);
        waitForConsumer = true;
    } else if (std::strcmp(argv[1], "--test-crash-pulse") == 0) {
        const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
        if (testMode == nullptr || std::strcmp(testMode, "1") != 0) {
            std::fprintf(stderr, "FAIL --test-crash-pulse requires isolated test mode\n");
            return 1;
        }
        frames = cardputer_bridge::audio_ipc::kTestPulseFrames * 2;
        activeDuration = std::chrono::milliseconds(50);
        crashWithoutCleanup = true;
    } else if (std::strcmp(argv[1], "--broker-test-pulse") == 0) {
        const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
        if (testMode == nullptr || std::strcmp(testMode, "1") != 0) {
            std::fprintf(stderr, "FAIL --broker-test-pulse requires isolated test mode\n");
            return 1;
        }
        frames = cardputer_bridge::audio_ipc::kTestPulseFrames * 2;
        activeDuration = std::chrono::milliseconds(300);
        lingerDuration = std::chrono::milliseconds(200);
        useBroker = true;
        waitForConsumer = true;
    } else if (std::strcmp(argv[1], "--broker-test-crash-pulse") == 0) {
        const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
        if (testMode == nullptr || std::strcmp(testMode, "1") != 0) {
            std::fprintf(stderr, "FAIL --broker-test-crash-pulse requires isolated test mode\n");
            return 1;
        }
        frames = cardputer_bridge::audio_ipc::kTestPulseFrames * 2;
        activeDuration = std::chrono::milliseconds(50);
        crashWithoutCleanup = true;
        useBroker = true;
    } else if (std::strcmp(argv[1], "--ff1-pulse") == 0) {
        const char* testMode = std::getenv("CARDPUTER_BRIDGE_AUDIO_TEST_MODE");
        if (testMode != nullptr && std::strcmp(testMode, "1") == 0) {
            std::fprintf(stderr, "FAIL --ff1-pulse must target production IPC\n");
            return 1;
        }
        frames = cardputer_bridge::audio_ipc::kSharedMemoryCapacityFrames;
        activeDuration = std::chrono::milliseconds(500);
        lingerDuration = std::chrono::milliseconds(3000);
        useBroker = true;
        waitForConsumer = true;
    } else {
        std::fprintf(stderr, "usage: audio_test_producer --test-pulse|--test-crash-pulse|--broker-test-pulse|--broker-test-crash-pulse|--cleanup-test-ipc|--ff1-pulse\n");
        return 64;
    }
    cardputer_bridge::audio_ipc::Producer producer;
    const bool opened = useBroker
        ? producer.OpenBroker(cardputer_bridge::audio_ipc::ResolveBrokerSocketPath())
        : producer.OpenOrCreate();
    if (!opened || !producer.WriteCountingPulse(frames)) {
        std::fprintf(stderr, "FAIL unable to publish shared-memory test pulse\n");
        return 1;
    }
    std::printf("READY audio_test_producer frames=%u\n", frames);
    std::fflush(stdout);
    if (waitForConsumer) {
        const auto consumerDeadline = std::chrono::steady_clock::now()
            + std::chrono::seconds(5);
        while (producer.ConsumedFrames() == 0
               && std::chrono::steady_clock::now() < consumerDeadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (!producer.RefreshLease()) {
                std::fprintf(stderr, "FAIL unable to refresh producer lease\n");
                return 1;
            }
        }
        if (producer.ConsumedFrames() == 0) {
            std::fprintf(stderr, "FAIL no consumer advanced shared read index\n");
            return 1;
        }
        // A producer-first test can accumulate a complete pulse before the
        // driver calls StartIO. Low-latency consumers intentionally discard
        // that stale backlog on attach, so publish one fresh real-time chunk.
        if (producer.ConsumedFrames() == frames) {
            std::array<Float32, cardputer_bridge::audio_ipc::kTestPulseFrames> fresh{};
            for (UInt32 index = 0; index < fresh.size(); ++index) {
                fresh[index] = (index / 240) % 2 == 0 ? 0.5F : -0.5F;
            }
            if (!producer.WriteFloat32(fresh.data(), static_cast<UInt32>(fresh.size()))) {
                std::fprintf(stderr, "FAIL unable to publish live-edge test pulse\n");
                return 1;
            }
        }
    }
    const auto activeDeadline = std::chrono::steady_clock::now() + activeDuration;
    while (std::chrono::steady_clock::now() < activeDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        if (!producer.RefreshLease()) {
            std::fprintf(stderr, "FAIL unable to refresh producer lease\n");
            return 1;
        }
    }
    if (crashWithoutCleanup) {
        std::_Exit(0);
    }
    std::printf(
        "OBSERVED audio_test_producer consumed_frames=%llu\n",
        static_cast<unsigned long long>(producer.ConsumedFrames()));
    producer.Stop();
    std::this_thread::sleep_for(lingerDuration);
    std::puts("PASS audio_test_producer stopped");
    return 0;
}
