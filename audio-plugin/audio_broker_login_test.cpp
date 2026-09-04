#include "AudioBridgeFDBroker.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>

using namespace cardputer_bridge::audio_ipc;

namespace {
void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

struct Client {
    int socket = -1;
    int buffer = -1;
    ~Client() {
        if (socket >= 0) close(socket);
        if (buffer >= 0) close(buffer);
    }
    bool Connect(const std::string& path) {
        return ConnectAndReceiveBuffer(path.c_str(), geteuid(), &socket, &buffer);
    }
    bool WaitForDisconnect() const {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (std::chrono::steady_clock::now() < deadline) {
            char byte;
            if (recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return false;
    }
};

void Run(const std::string& scenario, const std::string& path) {
    const uid_t none = static_cast<uid_t>(-1);
    const uid_t user = geteuid();
    Require(user != 0 && user != 88, "run as a regular user");
    std::atomic<uid_t> console{scenario == "login-after-windowserver" ? 88U : none};
    FDBrokerServer broker;
    Require(broker.Start(path, [&]() -> std::optional<uid_t> {
        const uid_t value = console.load();
        return value == none ? std::nullopt : std::optional<uid_t>(value);
    }), "broker must start before any user has logged in");
    {
        Client premature;
        Require(!premature.Connect(path), "must reject user before login");
    }
    console.store(user);
    Client active;
    Require(active.Connect(path), "login must enable current user without restarting broker");
    if (scenario == "login-after-windowserver" || scenario == "login-after-no-user") return;

    // Mark the isolated buffer active so revocation has to mute it as well.
    __atomic_store_n(&broker.buffer()->producer_active, 1, __ATOMIC_RELEASE);
    console.store(scenario == "logout" ? none : user + 1);
    Require(active.WaitForDisconnect(), "logout/user switch must close previous user's connection");
    Require(__atomic_load_n(&broker.buffer()->producer_active, __ATOMIC_ACQUIRE) == 0,
            "revoked connection must be muted");
    {
        Client previous;
        Require(!previous.Connect(path), "previous user must not reconnect after logout/switch");
    }
    console.store(user);
    Client returning;
    Require(returning.Connect(path), "returning user must reconnect without restarting broker");
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 2) return 64;
    char root[] = "/tmp/cb-broker-login.XXXXXX";
    if (!mkdtemp(root)) return 1;
    const std::string path = std::string(root) + "/audio.sock";
    int result = 0;
    try {
        Run(argv[1], path);
        std::printf("PASS broker_login scenario=%s\n", argv[1]);
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL broker_login scenario=%s: %s\n", argv[1], error.what());
        result = 1;
    }
    unlink((path + ".lock").c_str());
    rmdir(root);
    return result;
}
