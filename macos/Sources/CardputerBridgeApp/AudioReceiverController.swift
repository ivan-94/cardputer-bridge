import CardputerBridgeCore
import Combine
import CryptoKit
import Darwin
import Foundation
import Network

enum AudioReceiverStatus: String {
    case stopped
    case starting
    case listening
    case receiving
    case failed
}

final class AudioReceiverController: ObservableObject, @unchecked Sendable {
    @Published private(set) var status: AudioReceiverStatus = .stopped
    @Published private(set) var offer: AudioOfferMessage?
    @Published private(set) var metrics = AudioStreamMetrics()
    @Published private(set) var fault: String?
    @Published private(set) var systemMicrophoneReady = false

    var onAuthenticatedTestFrame: (@Sendable (UInt64) -> Void)?

    private let queue = DispatchQueue(label: "io.nexu.cardputerbridge.audio-udp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessionID: UInt64 = 0
    private var key = SymmetricKey(size: .bits256)
    // Counts every packet that passed AES-GCM authentication, including the
    // muted test frames used to prove a newly offered session. Jitter-buffer
    // metrics are reset when capture is muted, but this session proof must not
    // be reset or the App will continuously rotate otherwise healthy offers.
    private var authenticatedPacketCount = 0
    private var jitterBuffer = AudioJitterBuffer(sessionID: 0)
    private var resampler = try? PCM16ToFloat32Resampler()
    private let systemMicrophone = SystemMicrophoneProducer()
    private let runtimeProbeURL = ProcessInfo.processInfo.environment[
        "CARDPUTER_BRIDGE_AUDIO_PROBE_PATH"
    ].map(URL.init(fileURLWithPath:))

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func refreshSystemMicrophone() {
        queue.async { [weak self] in
            guard let self else { return }
            let ready = self.systemMicrophone.open()
            self.publish(
                fault: ready ? nil : "virtual_microphone_pipeline_unavailable",
                systemMicrophoneReady: ready
            )
        }
    }

    private func startOnQueue() {
        stopOnQueue()
        let newSessionID = UInt64.random(in: 1...UInt64.max)
        let newKey = SymmetricKey(size: .bits256)
        sessionID = newSessionID
        key = newKey
        authenticatedPacketCount = 0
        jitterBuffer = AudioJitterBuffer(sessionID: newSessionID)
        resampler = try? PCM16ToFloat32Resampler()
        let microphoneReady = systemMicrophone.open()
        publish(
            status: .starting,
            clearOffer: true,
            metrics: currentMetrics,
            fault: microphoneReady && resampler != nil
                ? nil
                : "virtual_microphone_pipeline_unavailable",
            systemMicrophoneReady: microphoneReady
        )

        do {
            let listener = try NWListener(using: .udp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                self?.handleListenerState(state, listener: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            publish(status: .failed, fault: "udp_listener_start_failed_\(error)")
        }
    }

    private func stopOnQueue() {
        systemMicrophone.stop()
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener?) {
        // Cancellation of the previous listener is asynchronous. Ignore its
        // late callback after a replacement session has already been installed.
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue,
                  let ipv4 = LocalIPv4.preferredAddress() else {
                publish(status: .failed, fault: "local_ipv4_unavailable")
                return
            }
            publish(
                status: .listening,
                offer: AudioOfferMessage(
                    ipv4: ipv4,
                    port: port,
                    sessionID: sessionID,
                    key: key
                ),
                metrics: currentMetrics,
                fault: nil
            )
        case .failed(let error):
            publish(status: .failed, fault: "udp_listener_failed_\(error)")
        case .cancelled:
            publish(status: .stopped, clearOffer: true)
        case .setup, .waiting:
            break
        @unknown default:
            publish(status: .failed, fault: "udp_listener_unknown_state")
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state {
                self?.remove(connection, identifier: identifier)
            } else if case .cancelled = state {
                self?.remove(connection, identifier: identifier)
            }
        }
        connection.start(queue: queue)
        receiveNext(on: connection, identifier: identifier)
    }

    private func remove(_ connection: NWConnection?, identifier: ObjectIdentifier) {
        connection?.cancel()
        connections.removeValue(forKey: identifier)
    }

    private func receiveNext(on connection: NWConnection, identifier: ObjectIdentifier) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data {
                self.consume(data)
            }
            if error == nil {
                self.receiveNext(on: connection, identifier: identifier)
            } else {
                self.remove(connection, identifier: identifier)
            }
        }
    }

    private func consume(_ datagram: Data) {
        do {
            let frame = try AudioDatagramV1.open(
                datagram,
                expectedSessionID: sessionID,
                key: key
            )
            authenticatedPacketCount += 1
            if frame.flags.contains(.muted) || frame.flags.contains(.end) {
                systemMicrophone.stop()
                resetAudioPipeline()
            } else if let batch = jitterBuffer.push(frame) {
                guard let floatSamples = try resampler?.convert(batch.pcm16) else {
                    publish(
                        status: .receiving,
                        metrics: currentMetrics,
                        fault: "audio_resample_failed"
                    )
                    return
                }
                let written = systemMicrophone.write(float32: floatSamples)
                let recovered = written || (
                    systemMicrophone.open()
                        && systemMicrophone.write(float32: floatSamples)
                )
                guard recovered else {
                    publish(
                        status: .receiving,
                        metrics: currentMetrics,
                        fault: "virtual_microphone_write_failed",
                        systemMicrophoneReady: false
                    )
                    return
                }
                publish(systemMicrophoneReady: true)
            }
            publish(status: .receiving, metrics: currentMetrics, fault: nil)
            if frame.flags.contains(.test) {
                onAuthenticatedTestFrame?(sessionID)
            }
        } catch {
            publish(fault: "audio_packet_rejected_\(error)")
        }
    }

    private func resetAudioPipeline() {
        jitterBuffer = AudioJitterBuffer(sessionID: sessionID)
        resampler = try? PCM16ToFloat32Resampler()
    }

    private var currentMetrics: AudioStreamMetrics {
        var current = jitterBuffer.metrics
        current.acceptedPackets = authenticatedPacketCount
        return current
    }

    private func publish(
        status: AudioReceiverStatus? = nil,
        offer: AudioOfferMessage? = nil,
        clearOffer: Bool = false,
        metrics: AudioStreamMetrics? = nil,
        fault: String? = nil,
        systemMicrophoneReady: Bool? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let status { self.status = status }
            if clearOffer { self.offer = nil }
            if let offer { self.offer = offer }
            if let metrics { self.metrics = metrics }
            if let systemMicrophoneReady {
                self.systemMicrophoneReady = systemMicrophoneReady
            }
            self.fault = fault
            self.publishRuntimeProbe()
        }
    }

    private func publishRuntimeProbe() {
        guard let runtimeProbeURL else { return }
        var payload: [String: Any] = [
            "status": status.rawValue,
            "accepted_packets": metrics.acceptedPackets,
            "missing_packets": metrics.missingPackets,
            "duplicate_or_late_packets": metrics.duplicateOrLatePackets,
            "signal_level": metrics.signalLevel,
            "system_microphone_ready": systemMicrophoneReady,
        ]
        if let offer {
            payload["listener_ipv4"] = offer.ipv4
            payload["listener_port"] = offer.port
            payload["session_id"] = String(format: "%016llx", offer.sessionID)
        }
        if let fault { payload["fault"] = fault }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: runtimeProbeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: runtimeProbeURL, options: .atomic)
    }
}

private final class SystemMicrophoneProducer {
    private let handle = CardputerAudioProducerCreate()

    deinit {
        CardputerAudioProducerDestroy(handle)
    }

    func open() -> Bool {
        CardputerAudioSystemInputIsPublished()
            && CardputerAudioProducerOpen(handle)
    }

    func write(float32 samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            return CardputerAudioProducerWriteFloat32(
                handle,
                baseAddress,
                buffer.count
            )
        }
    }

    func stop() {
        CardputerAudioProducerStop(handle)
    }
}

private enum LocalIPv4 {
    static func preferredAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let value = String(cString: host)
            let name = String(cString: interface.pointee.ifa_name)
            if name == "en0" { return value }
            if !value.hasPrefix("198.18.") { fallback = fallback ?? value }
        }
        return fallback
    }
}
