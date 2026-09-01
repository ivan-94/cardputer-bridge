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

    private let queue = DispatchQueue(label: "io.nexu.cardputerbridge.audio-tcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streamFramers: [ObjectIdentifier: AudioStreamFramer] = [:]
    private var candidateFrames: [ObjectIdentifier: [AudioFrameV1]] = [:]
    private var activeConnectionID: ObjectIdentifier?
    private var probeHeartbeatTimer: DispatchSourceTimer?
    private var sessionID: UInt64 = 0
    private var key = SymmetricKey(size: .bits256)
    // Counts every frame that passed AES-GCM authentication, including the
    // muted test frames used to prove a newly offered session. Stream-buffer
    // metrics are reset when capture is muted, but this session proof must not
    // be reset or the App will continuously rotate otherwise healthy offers.
    private var authenticatedPacketCount = 0
    private var authenticatedMissingCount = 0
    private var authenticatedDuplicateOrLateCount = 0
    private var expectedAuthenticatedSequence: UInt32?
    private var streamBuffer = AudioStreamBuffer(sessionID: 0)
    private var resampler = try? PCM16ToFloat32Resampler()
    private let systemMicrophone = SystemMicrophoneProducer()
    private var systemMicrophoneIsReady = false
    private var lastStreamPublishUptime: UInt64 = 0
    private var pendingStreamFault: String?
    private var streamPublishWorkItem: DispatchWorkItem?
    private static let streamPublishIntervalNanoseconds: UInt64 = 100_000_000
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
            self.systemMicrophoneIsReady = ready
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
        authenticatedMissingCount = 0
        authenticatedDuplicateOrLateCount = 0
        expectedAuthenticatedSequence = nil
        streamBuffer = AudioStreamBuffer(sessionID: newSessionID)
        resampler = try? PCM16ToFloat32Resampler()
        let microphoneReady = systemMicrophone.open()
        systemMicrophoneIsReady = microphoneReady
        lastStreamPublishUptime = 0
        pendingStreamFault = nil
        streamPublishWorkItem?.cancel()
        streamPublishWorkItem = nil
        publish(
            status: .starting,
            clearOffer: true,
            metrics: currentMetrics,
            fault: microphoneReady && resampler != nil
                ? nil
                : "virtual_microphone_pipeline_unavailable",
            systemMicrophoneReady: microphoneReady
        )
        startProbeHeartbeat()

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                self?.handleListenerState(state, listener: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            publish(status: .failed, fault: "tcp_listener_start_failed_\(error)")
        }
    }

    private func stopOnQueue() {
        systemMicrophone.stop()
        streamPublishWorkItem?.cancel()
        streamPublishWorkItem = nil
        probeHeartbeatTimer?.cancel()
        probeHeartbeatTimer = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        streamFramers.removeAll()
        candidateFrames.removeAll()
        activeConnectionID = nil
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
            publish(status: .failed, fault: "tcp_listener_failed_\(error)")
        case .cancelled:
            publish(status: .stopped, clearOffer: true)
        case .setup, .waiting:
            break
        @unknown default:
            publish(status: .failed, fault: "tcp_listener_unknown_state")
        }
    }

    private func accept(_ connection: NWConnection) {
        // Keep the current authenticated stream alive while a candidate proves
        // possession of the session key. An unauthenticated LAN client must not
        // be able to evict the real Cardputer by merely opening a TCP socket.
        guard connections.count < 4 else {
            connection.cancel()
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        candidateFrames[identifier] = []
        streamFramers[identifier] = AudioStreamFramer(
            frameBytes: AudioStreamFrameV1.frameBytes
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state {
                self?.remove(connection, identifier: identifier)
            } else if case .cancelled = state {
                self?.remove(connection, identifier: identifier)
            }
        }
        connection.start(queue: queue)
        receiveNext(on: connection, identifier: identifier)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.activeConnectionID != identifier else { return }
            self.remove(self.connections[identifier], identifier: identifier)
        }
    }

    private func remove(_ connection: NWConnection?, identifier: ObjectIdentifier) {
        connection?.cancel()
        connections.removeValue(forKey: identifier)
        streamFramers.removeValue(forKey: identifier)
        candidateFrames.removeValue(forKey: identifier)
        if activeConnectionID == identifier {
            activeConnectionID = nil
        }
    }

    private func receiveNext(on connection: NWConnection, identifier: ObjectIdentifier) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: AudioStreamFrameV1.frameBytes * 16
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty,
               var framer = self.streamFramers[identifier] {
                let frames = framer.append(data)
                self.streamFramers[identifier] = framer
                for frame in frames {
                    self.consume(
                        frame,
                        from: identifier,
                        connection: connection
                    )
                }
            }
            if error == nil, !isComplete {
                self.receiveNext(on: connection, identifier: identifier)
            } else {
                self.remove(connection, identifier: identifier)
            }
        }
    }

    private func consume(
        _ encryptedFrame: Data,
        from identifier: ObjectIdentifier,
        connection: NWConnection
    ) {
        do {
            let frame = try AudioStreamFrameV1.open(
                encryptedFrame,
                expectedSessionID: sessionID,
                key: key
            )
            if activeConnectionID != identifier {
                authenticateCandidate(
                    frame,
                    identifier: identifier,
                    connection: connection
                )
                return
            }
            consumeAuthenticated(frame)
        } catch {
            publishStreamProgress(fault: "audio_packet_rejected_\(error)")
            remove(connection, identifier: identifier)
        }
    }

    private func authenticateCandidate(
        _ frame: AudioFrameV1,
        identifier: ObjectIdentifier,
        connection: NWConnection
    ) {
        guard frame.flags.contains(.test), frame.flags.contains(.muted) else {
            remove(connection, identifier: identifier)
            return
        }
        var frames = candidateFrames[identifier] ?? []
        if let previous = frames.last,
           frame.sequence != previous.sequence &+ 1 {
            remove(connection, identifier: identifier)
            return
        }
        frames.append(frame)
        candidateFrames[identifier] = frames
        guard frames.count == 3 else { return }
        if let expected = expectedAuthenticatedSequence,
           let first = frames.first,
           first.sequence < expected {
            remove(connection, identifier: identifier)
            return
        }

        let otherConnections = connections.filter { $0.key != identifier }
        for (otherID, other) in otherConnections {
            other.cancel()
            connections.removeValue(forKey: otherID)
            streamFramers.removeValue(forKey: otherID)
            candidateFrames.removeValue(forKey: otherID)
        }
        activeConnectionID = identifier
        candidateFrames.removeValue(forKey: identifier)
        for testFrame in frames {
            consumeAuthenticated(testFrame)
        }
        onAuthenticatedTestFrame?(sessionID)
    }

    private func consumeAuthenticated(_ frame: AudioFrameV1) {
        guard observeAuthenticatedSequence(frame.sequence) else {
            publishStreamProgress()
            return
        }
        if frame.flags.contains(.muted) || frame.flags.contains(.end) {
            systemMicrophone.stop()
            resetAudioPipeline()
        } else if let batch = streamBuffer.push(frame) {
            guard let resampler,
                  let floatSamples = try? resampler.convert(batch.pcm16) else {
                publishStreamProgress(fault: "audio_resample_failed")
                return
            }
            let written = systemMicrophone.write(float32: floatSamples)
            let recovered = written || (
                systemMicrophone.open()
                    && systemMicrophone.write(float32: floatSamples)
            )
            guard recovered else {
                systemMicrophoneIsReady = false
                publishStreamProgress(fault: "virtual_microphone_write_failed")
                return
            }
            systemMicrophoneIsReady = true
        }
        publishStreamProgress()
    }

    private func observeAuthenticatedSequence(_ sequence: UInt32) -> Bool {
        authenticatedPacketCount += 1
        guard let expected = expectedAuthenticatedSequence else {
            expectedAuthenticatedSequence = sequence &+ 1
            return true
        }
        if sequence < expected {
            authenticatedDuplicateOrLateCount += 1
            return false
        }
        if sequence > expected {
            authenticatedMissingCount += Int(sequence - expected)
        }
        expectedAuthenticatedSequence = sequence &+ 1
        return true
    }

    private func resetAudioPipeline() {
        streamBuffer = AudioStreamBuffer(sessionID: sessionID)
        resampler = try? PCM16ToFloat32Resampler()
    }

    private var currentMetrics: AudioStreamMetrics {
        var current = streamBuffer.metrics
        current.acceptedPackets = authenticatedPacketCount
        current.missingPackets = authenticatedMissingCount
        current.duplicateOrLatePackets = authenticatedDuplicateOrLateCount
        return current
    }

    private func publishStreamProgress(fault: String? = nil) {
        if let fault {
            pendingStreamFault = fault
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- lastStreamPublishUptime
        guard elapsed >= Self.streamPublishIntervalNanoseconds else {
            if streamPublishWorkItem == nil {
                let remaining = Self.streamPublishIntervalNanoseconds - elapsed
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.streamPublishWorkItem = nil
                    self.publishStreamProgress()
                }
                streamPublishWorkItem = workItem
                queue.asyncAfter(
                    deadline: .now() + .nanoseconds(Int(remaining)),
                    execute: workItem
                )
            }
            return
        }
        streamPublishWorkItem?.cancel()
        streamPublishWorkItem = nil
        lastStreamPublishUptime = now
        let streamFault = pendingStreamFault
        pendingStreamFault = nil
        publish(
            status: .receiving,
            metrics: currentMetrics,
            fault: streamFault,
            systemMicrophoneReady: systemMicrophoneIsReady
        )
    }

    private func startProbeHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.publishRuntimeProbe()
            }
        }
        probeHeartbeatTimer = timer
        timer.resume()
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
            "transport": "tcp",
            "updated_at_unix_ms": Int(Date().timeIntervalSince1970 * 1_000),
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

enum LocalIPv4 {
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
