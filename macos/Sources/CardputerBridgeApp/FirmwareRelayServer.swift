import CardputerBridgeCore
import CryptoKit
import Foundation
import Network

/// A short-lived, one-artifact HTTP relay. The Mac verifies the signed release
/// manifest and artifact digest before this server becomes reachable. Its URL
/// is then delivered over the authenticated BLE control channel.
final class FirmwareRelayServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.nexu.cardputerbridge.firmware-relay")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var artifact = Data()
    private var expectedPath = ""
    private var startContinuation: CheckedContinuation<URL, Error>?

    func prepare(release: FirmwareReleasePayload) async throws -> URL {
        guard let source = URL(string: release.firmware.ota.url),
              source.scheme == "https" else {
            throw FirmwareRelayError.invalidArtifact
        }
        let (data, response) = try await URLSession.shared.data(from: source)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count == release.firmware.ota.bytes,
              SHA256.hash(data: data).relayHex == release.firmware.ota.sha256 else {
            throw FirmwareRelayError.invalidArtifact
        }
        return try await prepare(data: data)
    }

    #if DEBUG
    func prepareLocal(imageURL: URL) async throws -> URL {
        let values = try imageURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 4 * 1_024 * 1_024 else {
            throw FirmwareRelayError.invalidArtifact
        }
        return try await prepare(data: Data(contentsOf: imageURL))
    }
    #endif

    private func prepare(data: Data) async throws -> URL {
        guard let address = LocalIPv4.preferredAddress() else {
            throw FirmwareRelayError.localNetworkUnavailable
        }
        let token = UUID().uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        let path = "/cardputer-bridge/\(token).bin"
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                stopOnQueue(resumingWith: FirmwareRelayError.cancelled)
                artifact = data
                expectedPath = path
                startContinuation = continuation
                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        self?.handleListenerState(
                            state,
                            listener: listener,
                            address: address,
                            path: path
                        )
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                } catch {
                    failStart(error)
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue(resumingWith: FirmwareRelayError.cancelled)
        }
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        startContinuation?.resume(throwing: FirmwareRelayError.cancelled)
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listener: NWListener?,
        address: String,
        path: String
    ) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue,
                  let url = URL(string: "http://\(address):\(port)\(path)"),
                  let continuation = startContinuation else {
                failStart(FirmwareRelayError.localNetworkUnavailable)
                return
            }
            startContinuation = nil
            continuation.resume(returning: url)
        case .failed(let error):
            failStart(error)
        case .cancelled:
            if let continuation = startContinuation {
                startContinuation = nil
                continuation.resume(throwing: FirmwareRelayError.cancelled)
            }
        case .setup, .waiting:
            break
        @unknown default:
            failStart(FirmwareRelayError.localNetworkUnavailable)
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        requestBuffers[identifier] = Data()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state {
                self?.remove(connection, identifier: identifier)
            } else if case .cancelled = state {
                self?.remove(connection, identifier: identifier)
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, identifier: identifier)
    }

    private func receiveRequest(
        on connection: NWConnection,
        identifier: ObjectIdentifier
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8_192
        ) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.requestBuffers[identifier, default: Data()].append(data)
            }
            guard error == nil,
                  let request = self.requestBuffers[identifier],
                  request.count <= 8_192 else {
                self.sendStatus(400, on: connection, identifier: identifier)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: request, on: connection, identifier: identifier)
            } else if complete {
                self.sendStatus(400, on: connection, identifier: identifier)
            } else {
                self.receiveRequest(on: connection, identifier: identifier)
            }
        }
    }

    private func respond(
        to request: Data,
        on connection: NWConnection,
        identifier: ObjectIdentifier
    ) {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            sendStatus(400, on: connection, identifier: identifier)
            return
        }
        let expected10 = "GET \(expectedPath) HTTP/1.0"
        let expected11 = "GET \(expectedPath) HTTP/1.1"
        guard requestLine == expected10 || requestLine == expected11 else {
            let status = requestLine.hasPrefix("GET ") ? 404 : 405
            sendStatus(status, on: connection, identifier: identifier)
            return
        }
        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(artifact.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8
        )
        response.append(artifact)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.remove(connection, identifier: identifier)
        })
    }

    private func sendStatus(
        _ status: Int,
        on connection: NWConnection,
        identifier: ObjectIdentifier
    ) {
        let reason: String
        switch status {
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Bad Request"
        }
        let response = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.remove(connection, identifier: identifier)
        })
    }

    private func remove(
        _ connection: NWConnection?,
        identifier: ObjectIdentifier
    ) {
        connection?.cancel()
        connections.removeValue(forKey: identifier)
        requestBuffers.removeValue(forKey: identifier)
    }

    private func failStart(_ error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: error)
    }

    private func stopOnQueue(resumingWith error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        requestBuffers.removeAll()
        artifact.removeAll(keepingCapacity: false)
        expectedPath = ""
        continuation?.resume(throwing: error)
    }
}

enum FirmwareRelayError: LocalizedError {
    case invalidArtifact
    case localNetworkUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidArtifact:
            "固件下载或完整性校验失败。"
        case .localNetworkUnavailable:
            "Mac 没有可供 Cardputer 访问的局域网地址。"
        case .cancelled:
            "固件更新已取消。"
        }
    }
}

private extension SHA256.Digest {
    var relayHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
