#pragma once

#include "AudioBridgeSharedMemory.hpp"

#include <sys/types.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <thread>

namespace cardputer_bridge::audio_ipc {

constexpr const char* kBrokerSocketPath = "/tmp/io.nexu.cardputerbridge.audio-v1.sock";
constexpr UInt32 kBrokerProtocolMagic = 0x43424644;
constexpr UInt32 kBrokerProtocolVersion = 1;

struct BrokerHello {
    UInt32 magic;
    UInt32 version;
    std::uint64_t mapping_size;
};

class FDBrokerServer {
public:
    using ProducerUIDResolver = std::function<std::optional<uid_t>()>;
    FDBrokerServer() = default;
    FDBrokerServer(const FDBrokerServer&) = delete;
    FDBrokerServer& operator=(const FDBrokerServer&) = delete;
    ~FDBrokerServer();

    bool Start(const std::string& socketPath, uid_t allowedProducerUID);
    // Resolver runs on the broker worker, never the realtime audio thread.
    // It may return no user until login; it must not throw.
    bool Start(const std::string& socketPath, ProducerUIDResolver resolveProducerUID);
    void Stop() noexcept;
    int DuplicateBufferDescriptor() const noexcept;
    SharedAudioBuffer* buffer() const noexcept { return buffer_; }
    std::uint64_t rejected_peers() const noexcept;

private:
    void Serve() noexcept;
    bool IsAuthorized(uid_t peerUID) const noexcept;

    std::string socket_path_;
    ProducerUIDResolver resolve_producer_uid_;
    int ownership_lock_descriptor_{-1};
    int buffer_descriptor_{-1};
    SharedAudioBuffer* buffer_{nullptr};
    std::atomic<int> listener_descriptor_{-1};
    std::atomic<int> client_descriptor_{-1};
    std::atomic<bool> running_{false};
    std::atomic<std::uint64_t> rejected_peers_{0};
    std::uint64_t socket_device_{0};
    std::uint64_t socket_inode_{0};
    std::thread worker_;
};

std::optional<uid_t> ConsoleUserUID() noexcept;
std::optional<uid_t> ExpectedBrokerUID() noexcept;
const char* ResolveBrokerSocketPath() noexcept;
bool ConnectAndReceiveBuffer(
    const char* socketPath,
    uid_t expectedBrokerUID,
    int* outControlDescriptor,
    int* outBufferDescriptor) noexcept;

}  // namespace cardputer_bridge::audio_ipc
