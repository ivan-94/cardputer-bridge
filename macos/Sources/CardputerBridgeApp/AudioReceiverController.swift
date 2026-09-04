import CardputerBridgeCore
import Combine
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
    private struct ReceiveDiagnostics: Sendable {
        var callbacks = 0
        var bytes = 0
        var framed = 0
        var decoded = 0
        var live = 0
        var writes = 0
        var rejected = 0
        var lastError = ""
        var lastDatagramUptimeNanoseconds: UInt64?
        var maximumDatagramGapNanoseconds: UInt64 = 0
        var datagramGapsOver100Milliseconds = 0
        var datagramGapsOver200Milliseconds = 0
        var maximumReceiverQueueDelayNanoseconds: UInt64 = 0
        var maximumProcessingNanoseconds: UInt64 = 0
    }

    @Published private(set) var status: AudioReceiverStatus = .stopped
    @Published private(set) var offer: AudioOfferMessage?
    @Published private(set) var metrics = AudioStreamMetrics()
    @Published private(set) var fault: String?
    @Published private(set) var systemMicrophoneReady = false

    var onSessionTestFrame: (@Sendable (UInt64) -> Void)?

    // Network.framework only schedules another UDP delivery after the current
    // receive callback returns. Keep that callback limited to rearming receive
    // and handing immutable data to the processing queue; decoding,
    // resampling and writing the HAL ring must never apply backpressure to the
    // kernel's UDP receive path.
    private let networkQueue = DispatchQueue(
        label: "io.nexu.cardputerbridge.audio-udp-receive",
        qos: .userInteractive
    )
    private let queue = DispatchQueue(
        label: "io.nexu.cardputerbridge.audio-udp-process",
        qos: .userInitiated
    )
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var candidateFrames: [ObjectIdentifier: [AudioFrameV2]] = [:]
    private var activeConnectionID: ObjectIdentifier?
    private var probeHeartbeatTimer: DispatchSourceTimer?
    private var sessionID: UInt64 = 0
    // Count valid frames in this session, including muted reachability probes.
    // A session ID is a routing discriminator, not proof of identity.
    private var receiveDiagnostics = ReceiveDiagnostics()
    @Published private var publishedReceiveDiagnostics = ReceiveDiagnostics()
    private var lastConnectionEvent = ""
    @Published private var publishedLastConnectionEvent = ""
    private var streamBuffer = AudioJitterBuffer(sessionID: 0)
    private var retiredStreamMetrics = AudioStreamMetrics()
    private var resampler = try? PCM16ToFloat32Resampler()
    private let systemMicrophone = SystemMicrophoneProducer()
    private var systemMicrophoneIsReady = false
    private var lastStreamPublishUptime: UInt64 = 0
    private var pendingStreamFault: String?
    private var streamPublishWorkItem: DispatchWorkItem?
    private var microphoneDrainToken: UInt64 = 0
    private static let streamPublishIntervalNanoseconds: UInt64 = 100_000_000
    private static let microphoneDrainDelayMilliseconds = 200
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
        sessionID = newSessionID
        receiveDiagnostics = ReceiveDiagnostics()
        retiredStreamMetrics = AudioStreamMetrics()
        streamBuffer = AudioJitterBuffer(sessionID: newSessionID)
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
            let parameters = NWParameters.udp
            parameters.serviceClass = .interactiveVoice
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                self?.queue.async { [weak self, weak listener] in
                    self?.handleListenerState(state, listener: listener)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { [weak self] in
                    self?.accept(connection)
                }
            }
            listener.start(queue: networkQueue)
        } catch {
            publish(status: .failed, fault: "udp_listener_start_failed_\(error)")
        }
    }

    private func stopOnQueue() {
        cancelMicrophoneDrain()
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
                    sessionID: sessionID
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
        // Keep the current stream until a candidate supplies three valid
        // session probes. Plaintext audio has no cryptographic authentication.
        guard connections.count < 4 else {
            connection.cancel()
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        candidateFrames[identifier] = []
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            self?.queue.async { [weak self, weak connection] in
                if case .failed(let error) = state {
                    self?.remove(
                        connection,
                        identifier: identifier,
                        reason: "connection_failed_\(error)"
                    )
                } else if case .cancelled = state {
                    self?.remove(
                        connection,
                        identifier: identifier,
                        reason: "connection_cancelled"
                    )
                }
            }
        }
        connection.start(queue: networkQueue)
        receiveNext(on: connection, identifier: identifier)
        queue.asyncAfter(
            deadline: .now() + AudioSessionRecovery.candidateValidationTimeoutSeconds
        ) { [weak self] in
            guard let self, self.activeConnectionID != identifier else { return }
            self.remove(
                self.connections[identifier],
                identifier: identifier,
                reason: "candidate_validation_timeout"
            )
        }
    }

    private func remove(
        _ connection: NWConnection?,
        identifier: ObjectIdentifier,
        reason: String
    ) {
        guard connections[identifier] != nil else { return }
        lastConnectionEvent = reason
        receiveDiagnostics.lastError = reason
        connection?.cancel()
        connections.removeValue(forKey: identifier)
        candidateFrames.removeValue(forKey: identifier)
        if activeConnectionID == identifier {
            activeConnectionID = nil
        }
    }

    private func receiveNext(on connection: NWConnection, identifier: ObjectIdentifier) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            let arrivalUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            // Rearm before doing any packet work. Network callbacks run on a
            // dedicated serial queue, so their order is preserved while the
            // processing queue may briefly lag without stopping UDP intake.
            if error == nil {
                self.receiveNext(on: connection, identifier: identifier)
            }
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection,
                      self.connections[identifier] === connection else { return }
                self.handleReceive(
                    data,
                    error: error,
                    arrivalUptimeNanoseconds: arrivalUptimeNanoseconds,
                    from: identifier,
                    connection: connection
                )
            }
        }
    }

    private func handleReceive(
        _ data: Data?,
        error: NWError?,
        arrivalUptimeNanoseconds: UInt64,
        from identifier: ObjectIdentifier,
        connection: NWConnection
    ) {
        let processingStart = DispatchTime.now().uptimeNanoseconds
        receiveDiagnostics.maximumReceiverQueueDelayNanoseconds = max(
            receiveDiagnostics.maximumReceiverQueueDelayNanoseconds,
            processingStart &- arrivalUptimeNanoseconds
        )
        receiveDiagnostics.callbacks += 1
        if let data, !data.isEmpty {
            receiveDiagnostics.bytes += data.count
            if activeConnectionID == identifier {
                recordDatagramArrival(at: arrivalUptimeNanoseconds)
            }
            consume(data, from: identifier, connection: connection)
        }
        if let error {
            remove(
                connection,
                identifier: identifier,
                reason: "receive_failed_\(error)"
            )
        }
        receiveDiagnostics.maximumProcessingNanoseconds = max(
            receiveDiagnostics.maximumProcessingNanoseconds,
            DispatchTime.now().uptimeNanoseconds &- processingStart
        )
    }

    private func consume(
        _ datagram: Data,
        from identifier: ObjectIdentifier,
        connection: NWConnection
    ) {
        do {
            let datagramFrames = try AudioRedundantDatagramV2.decode(
                datagram,
                expectedSessionID: sessionID
            )
            receiveDiagnostics.framed += datagramFrames.count
            receiveDiagnostics.decoded += datagramFrames.count
            for datagramFrame in datagramFrames {
                let frame = datagramFrame.frame
                if activeConnectionID != identifier {
                    validateCandidate(
                        frame,
                        identifier: identifier,
                        connection: connection
                    )
                    continue
                }
                consumeValidated(
                    frame,
                    source: datagramFrame.isRedundant ? .redundant : .primary
                )
            }
        } catch {
            receiveDiagnostics.rejected += 1
            receiveDiagnostics.lastError = "packet_\(error)"
            publishStreamProgress(fault: "audio_packet_rejected_\(error)")
            remove(
                connection,
                identifier: identifier,
                reason: "packet_rejected_\(error)"
            )
        }
    }

    private func validateCandidate(
        _ frame: AudioFrameV2,
        identifier: ObjectIdentifier,
        connection: NWConnection
    ) {
        guard frame.flags.contains(.test), frame.flags.contains(.muted) else {
            remove(
                connection,
                identifier: identifier,
                reason: "candidate_missing_test_proof"
            )
            return
        }
        var frames = candidateFrames[identifier] ?? []
        if let previous = frames.last {
            if frame.sequence == previous.sequence {
                return
            }
            if frame.sequence != previous.sequence &+ 1 {
                frames = []
            }
        }
        frames.append(frame)
        candidateFrames[identifier] = frames
        guard frames.count == 3 else { return }

        let otherConnections = connections.filter { $0.key != identifier }
        for (otherID, other) in otherConnections {
            other.cancel()
            connections.removeValue(forKey: otherID)
            candidateFrames.removeValue(forKey: otherID)
        }
        activeConnectionID = identifier
        // Candidate proof packets are intentionally sparse and must not
        // contaminate live-stream timing. Begin measuring with the next UDP
        // datagram from the selected endpoint.
        receiveDiagnostics.lastDatagramUptimeNanoseconds = nil
        candidateFrames.removeValue(forKey: identifier)
        for testFrame in frames {
            consumeValidated(testFrame, source: .primary)
        }
        onSessionTestFrame?(sessionID)
    }

    private func recordDatagramArrival(at now: UInt64) {
        if let previous = receiveDiagnostics.lastDatagramUptimeNanoseconds {
            let gap = now &- previous
            receiveDiagnostics.maximumDatagramGapNanoseconds = max(
                receiveDiagnostics.maximumDatagramGapNanoseconds,
                gap
            )
            if gap >= 100_000_000 {
                receiveDiagnostics.datagramGapsOver100Milliseconds += 1
            }
            if gap >= 200_000_000 {
                receiveDiagnostics.datagramGapsOver200Milliseconds += 1
            }
        }
        receiveDiagnostics.lastDatagramUptimeNanoseconds = now
    }

    private func consumeValidated(
        _ frame: AudioFrameV2,
        source: AudioFrameSource
    ) {
        if frame.flags.contains(.end) {
            if let tail = streamBuffer.finish() {
                writeToSystemMicrophone(tail)
            }
            beginMicrophoneDrain()
            resetAudioPipeline()
        } else if frame.flags.contains(.muted) {
            cancelMicrophoneDrain()
            systemMicrophone.stop()
            resetAudioPipeline()
        } else if let batch = streamBuffer.push(frame, source: source) {
            cancelMicrophoneDrain()
            writeToSystemMicrophone(batch)
        }
        publishStreamProgress()
    }

    private func writeToSystemMicrophone(_ batch: AudioStreamBatch) {
        receiveDiagnostics.live += 1
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
        receiveDiagnostics.writes += 1
        systemMicrophoneIsReady = true
    }

    // Keep the producer alive long enough for Core Audio to consume the
    // bounded reorder tail. ABI v3 intentionally exposes no diagnostic
    // counters; a short fixed drain keeps App and installed driver compatible.
    private func beginMicrophoneDrain() {
        microphoneDrainToken &+= 1
        let token = microphoneDrainToken
        guard systemMicrophone.refreshLease() else {
            systemMicrophone.stop()
            return
        }
        queue.asyncAfter(
            deadline: .now() + .milliseconds(Self.microphoneDrainDelayMilliseconds)
        ) { [weak self] in
            guard let self, token == self.microphoneDrainToken else { return }
            self.systemMicrophone.stop()
        }
    }

    private func cancelMicrophoneDrain() {
        microphoneDrainToken &+= 1
    }

    private func resetAudioPipeline() {
        retiredStreamMetrics.accumulate(streamBuffer.metrics)
        streamBuffer = AudioJitterBuffer(sessionID: sessionID)
        resampler = try? PCM16ToFloat32Resampler()
    }

    private var currentMetrics: AudioStreamMetrics {
        var metrics = retiredStreamMetrics
        metrics.accumulate(streamBuffer.metrics)
        return metrics
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
        let receiveDiagnostics = self.receiveDiagnostics
        let lastConnectionEvent = self.lastConnectionEvent
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let status { self.status = status }
            if clearOffer { self.offer = nil }
            if let offer { self.offer = offer }
            if let metrics { self.metrics = metrics }
            if let systemMicrophoneReady {
                self.systemMicrophoneReady = systemMicrophoneReady
            }
            self.publishedReceiveDiagnostics = receiveDiagnostics
            self.publishedLastConnectionEvent = lastConnectionEvent
            self.fault = fault
            self.publishRuntimeProbe()
        }
    }

    private func publishRuntimeProbe() {
        guard let runtimeProbeURL else { return }
        var payload: [String: Any] = [
            "status": status.rawValue,
            "transport": "udp",
            "audio_format": "pcm16le-v2",
            "audio_encrypted": false,
            "updated_at_unix_ms": Int(Date().timeIntervalSince1970 * 1_000),
            "accepted_packets": metrics.acceptedPackets,
            "missing_packets": metrics.missingPackets,
            "recovered_packets": metrics.recoveredPackets,
            "missing_capture_samples": metrics.missingCaptureSamples,
            "duplicate_or_late_packets": metrics.duplicateOrLatePackets,
            "signal_level": metrics.signalLevel,
            "system_microphone_ready": systemMicrophoneReady,
            "receive_callbacks": publishedReceiveDiagnostics.callbacks,
            "receive_bytes": publishedReceiveDiagnostics.bytes,
            "framed_packets": publishedReceiveDiagnostics.framed,
            "decoded_packets": publishedReceiveDiagnostics.decoded,
            "live_batches": publishedReceiveDiagnostics.live,
            "microphone_writes": publishedReceiveDiagnostics.writes,
            "rejected_packets": publishedReceiveDiagnostics.rejected,
            "last_receive_error": publishedReceiveDiagnostics.lastError,
            "last_connection_event": publishedLastConnectionEvent,
            "maximum_receive_gap_ms": Double(
                publishedReceiveDiagnostics.maximumDatagramGapNanoseconds
            ) / 1_000_000,
            "receive_gap_over_100ms_count":
                publishedReceiveDiagnostics.datagramGapsOver100Milliseconds,
            "receive_gap_over_200ms_count":
                publishedReceiveDiagnostics.datagramGapsOver200Milliseconds,
            "maximum_receiver_queue_delay_ms": Double(
                publishedReceiveDiagnostics.maximumReceiverQueueDelayNanoseconds
            ) / 1_000_000,
            "maximum_packet_processing_ms": Double(
                publishedReceiveDiagnostics.maximumProcessingNanoseconds
            ) / 1_000_000,
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

    func refreshLease() -> Bool {
        CardputerAudioProducerRefreshLease(handle)
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
