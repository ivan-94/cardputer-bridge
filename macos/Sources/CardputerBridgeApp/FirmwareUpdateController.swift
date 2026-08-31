import CardputerBridgeCore
import CryptoKit
import Darwin
import Foundation

@MainActor
final class FirmwareUpdateController: ObservableObject {
    enum USBReadiness: Equatable {
        case idle
        case checking
        case ready(USBFlashTarget)
        case unavailable(message: String)
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(FirmwareInstallPlan)
        case downloading
        case flashing(progress: Int)
        case ota(progress: Int)
        case complete(version: String)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: FirmwareReleasePayload?
    @Published private(set) var usbReadiness: USBReadiness = .idle

    private var lastProbedPorts: [String] = []
    private var relay: FirmwareRelayServer?

    private let manifestURL = URL(
        string: "https://github.com/ivan-94/cardputer-bridge/releases/latest/download/cardputer-bridge-release.json"
    )!

    var isUSBReady: Bool {
        if case .ready = usbReadiness { return true }
        return false
    }

    func refreshUSBReadiness(force: Bool = false) {
        guard usbReadiness != .checking else { return }
        let ports = localUSBSerialPorts()

        if case .ready(let target) = usbReadiness,
           ports.contains(target.port) {
            return
        }
        if ports.isEmpty {
            lastProbedPorts = []
            usbReadiness = .unavailable(
                message: "请连接 Cardputer，并确认使用的是可传输数据的 USB-C 线。"
            )
            return
        }
        if !force, ports == lastProbedPorts { return }

        lastProbedPorts = ports
        usbReadiness = .checking
        Task {
            do {
                guard ports.count == 1 else {
                    throw UpdateFailure.multipleDevices
                }
                let espflash = try await EspflashTool.prepare()
                let port = ports[0]
                let output = try await Task.detached(priority: .userInitiated) {
                    try run(
                        espflash,
                        [
                            "board-info",
                            "--chip", "esp32s3",
                            "--port", port,
                            "--non-interactive",
                            "--skip-update-check",
                            "--before", "usb-reset",
                            "--after", "hard-reset",
                        ]
                    )
                }.value
                guard let target = USBFlashTargetProbe.validatedTarget(
                    port: port,
                    boardInfo: output
                ) else {
                    throw UpdateFailure.unsupportedUSBTarget
                }
                usbReadiness = .ready(target)
            } catch {
                usbReadiness = .unavailable(message: usbMessage(for: error))
            }
        }
    }

    func check(identity: DeviceFirmwareIdentity?) {
        guard phase != .checking else { return }
        relay?.stop()
        relay = nil
        release = nil
        phase = .checking
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(
                    from: manifestURL
                )
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    throw UpdateFailure.releaseUnavailable
                }
                let signed = try JSONDecoder().decode(
                    SignedFirmwareRelease.self,
                    from: data
                )
                try signed.verify(
                    trustedKeys: FirmwareReleaseTrust.productionKeys
                )
                release = signed.payload
                let status = identity?.status ?? FirmwareDeviceStatus(
                    version: nil,
                    layoutVersion: 1,
                    otaCapable: false
                )
                phase = .available(
                    FirmwareUpdatePolicy.plan(
                        device: status,
                        release: signed.payload,
                        appVersion: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "0.0.0"
                    )
                )
            } catch {
                phase = .failed(message: userMessage(for: error))
            }
        }
    }

    func beginOTA(using bluetooth: BLEBridgeController) {
        guard let release else { return }
        let usbPowerVerified = !localUSBSerialPorts().isEmpty
        switch FirmwareOTAPreflightPolicy.evaluate(
            bluetooth.deviceTelemetry,
            usbPowerVerified: usbPowerVerified
        ) {
        case .ready:
            break
        case .telemetryUnavailable:
            phase = .failed(
                message: "正在读取 Cardputer 的电量和网络状态，请稍后重试。"
            )
            return
        case .wifiUnavailable:
            phase = .failed(
                message: "Cardputer 尚未接入 Wi-Fi。请先连接 2.4 GHz 网络再更新。"
            )
            return
        case .lowBattery(let percent):
            phase = .failed(
                message: "Cardputer 电量仅 \(percent)%。请充至 30% 以上，或用 USB 连接这台 Mac 后重试。"
            )
            return
        case .weakWiFi(let rssi):
            phase = .failed(
                message: "Cardputer 的 Wi-Fi 信号过弱（\(rssi) dBm）。请靠近路由器后重试。"
            )
            return
        }
        relay?.stop()
        relay = nil
        phase = .downloading
        Task {
            let candidate = FirmwareRelayServer()
            do {
                let url = try await candidate.prepare(release: release)
                guard self.release?.version == release.version else {
                    candidate.stop()
                    return
                }
                relay = candidate
                if bluetooth.startFirmwareOTA(
                    version: release.version,
                    url: url.absoluteString,
                    usbPowerVerified: usbPowerVerified
                ) {
                    phase = .ota(progress: 0)
                } else {
                    candidate.stop()
                    relay = nil
                    phase = .failed(
                        message: "Cardputer 控制通道尚未就绪，请恢复蓝牙连接后重试。"
                    )
                }
            } catch {
                candidate.stop()
                relay = nil
                phase = .failed(
                    message: "Mac 无法准备局域网固件更新：\(error.localizedDescription)"
                )
            }
        }
    }

    func observe(_ event: FirmwareOTAEvent?) {
        guard let event else { return }
        switch event.phase {
        case "downloading":
            phase = .ota(progress: event.progress)
        case "restarting":
            phase = .ota(progress: 100)
            relay?.stop()
            relay = nil
        case "failed":
            phase = .failed(message: otaFailureMessage(error: event.error))
            relay?.stop()
            relay = nil
        default:
            break
        }
    }

    private func otaFailureMessage(error: Int) -> String {
        switch error {
        case 0x7002:
            "Cardputer 无法连接这台 Mac 的更新服务。请确认两台设备位于同一局域网，并允许 Cardputer Bridge 接收入站连接；当前固件不受影响。"
        case 0x101:
            "Cardputer 可用内存不足，更新已安全停止。请重新启动设备后重试；当前固件不受影响。"
        case 0x7101:
            "Cardputer 尚未接入 Wi-Fi。请先连接 2.4 GHz 网络再更新。"
        case 0x7102:
            "Cardputer 暂时无法读取电量。请用 USB 连接这台 Mac 后重试。"
        case 0x7103:
            "Cardputer 电量低于 30%。请充电，或用 USB 连接这台 Mac 后重试。"
        case 0x7104:
            "Cardputer 的 Wi-Fi 信号过弱。请靠近路由器后重试。"
        default:
            "Cardputer 无法完成固件更新（错误 \(error)）。当前固件不受影响。"
        }
    }

    func observeIdentity(_ identity: DeviceFirmwareIdentity?) {
        guard let identity,
              let release,
              identity.firmwareVersion == release.version else { return }
        relay?.stop()
        relay = nil
        phase = .complete(version: release.version)
    }

    func installOverUSB() {
        guard let release else { return }
        phase = .downloading
        Task {
            do {
                let package = try await USBFirmwarePackage.prepare(release)
                phase = .flashing(progress: 0)
                try await Task.detached(priority: .userInitiated) { [self] in
                    try await package.install { [weak self] progress in
                        Task { @MainActor in
                            self?.phase = .flashing(progress: progress)
                        }
                    }
                }.value
                phase = .complete(version: release.version)
            } catch {
                phase = .failed(message: userMessage(for: error))
            }
        }
    }

    private func userMessage(for error: Error) -> String {
        switch error {
        case UpdateFailure.releaseUnavailable:
            "尚无可公开下载的正式固件。GitHub 仓库公开并发布首个 Release 后，这里会自动发现更新。"
        case UpdateFailure.deviceNotFound:
            "没有发现 Cardputer USB 设备。连接数据线后重试；若仍未发现，请按住 G0 再重新上电。"
        case UpdateFailure.multipleDevices:
            "检测到多台可烧录设备。请只保留一台 Cardputer 后重试。"
        case UpdateFailure.unsupportedUSBTarget:
            "USB 设备已连接，但无法确认它是可烧写的 Cardputer-ADV。"
        case UpdateFailure.bootVerificationFailed:
            "固件已写入，但未确认 Cardputer Bridge 成功启动。请保持 USB 连接并重试。"
        case UpdateFailure.helperIntegrity:
            "烧录工具未通过完整性校验，已停止安装。"
        case UpdateFailure.artifactIntegrity:
            "固件文件未通过 SHA-256 校验，已停止安装。"
        case UpdateFailure.flashFailed(let detail):
            "固件烧录失败：\(detail)"
        default:
            "更新失败：\(error.localizedDescription)"
        }
    }

    private func usbMessage(for error: Error) -> String {
        switch error {
        case UpdateFailure.multipleDevices:
            "检测到多台 USB 串口设备。请只保留一台 Cardputer。"
        case UpdateFailure.unsupportedUSBTarget:
            "已找到 USB 设备，但未识别为可烧写的 Cardputer-ADV。"
        case UpdateFailure.helperIntegrity:
            "无法安全准备 USB 检测工具，请检查网络后重试。"
        default:
            "无法与 Cardputer 握手。请更换数据线或 USB 接口后重试。"
        }
    }
}

private enum UpdateFailure: Error {
    case releaseUnavailable
    case deviceNotFound
    case multipleDevices
    case helperIntegrity
    case artifactIntegrity
    case unsupportedUSBTarget
    case bootVerificationFailed
    case flashFailed(String)
}

private struct USBFirmwarePackage: Sendable {
    let release: FirmwareReleasePayload
    let files: [String: URL]
    let espflash: URL

    static func prepare(
        _ release: FirmwareReleasePayload
    ) async throws -> USBFirmwarePackage {
        let root = try applicationSupportRoot()
            .appending(path: "updates/\(release.version)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var files: [String: URL] = [:]
        for artifact in release.firmware.usb {
            guard let source = URL(string: artifact.url) else {
                throw UpdateFailure.artifactIntegrity
            }
            let destination = root.appending(path: "\(artifact.role).bin")
            let (data, response) = try await URLSession.shared.data(from: source)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  data.count == artifact.bytes,
                  SHA256.hash(data: data).hex == artifact.sha256 else {
                throw UpdateFailure.artifactIntegrity
            }
            try data.write(to: destination, options: .atomic)
            files[artifact.role] = destination
        }
        return USBFirmwarePackage(
            release: release,
            files: files,
            espflash: try await EspflashTool.prepare()
        )
    }

    func install(
        progress: @escaping @Sendable (Int) -> Void
    ) async throws {
        var port = try discoverSinglePort(using: espflash)

        // Write the future factory image first and the bootloader last. A power
        // loss at any earlier point leaves the previously bootable loader in
        // place; NVS at 0x9000 is deliberately never erased.
        let steps: [(role: String, offset: String)] = [
            ("factory", "0x10000"),
            ("otadata", "0x610000"),
            ("partition_table", "0x8000"),
            ("bootloader", "0x0"),
        ]
        for (index, step) in steps.enumerated() {
            guard let file = files[step.role] else {
                throw UpdateFailure.artifactIntegrity
            }
            let arguments = [
                "write-bin",
                "--chip", "esp32s3",
                "--port", port,
                "--non-interactive",
                "--skip-update-check",
                "--before", index == 0 ? "usb-reset" : "no-reset",
                "--after", index == steps.count - 1 ? "hard-reset" : "no-reset",
                step.offset,
                file.path,
            ]
            // Keep argument ownership local to make accidental shell
            // interpolation impossible; Process never invokes a shell.
            do {
                _ = try run(espflash, arguments)
            } catch {
                throw UpdateFailure.flashFailed(error.localizedDescription)
            }
            progress((index + 1) * 100 / steps.count)
        }

        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let rediscovered = try? discoverSinglePort(using: espflash) else {
                continue
            }
            port = rediscovered
            if firmwareIsRunning(at: port) { return }
        }
        throw UpdateFailure.bootVerificationFailed
    }

    fileprivate static func applicationSupportRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(
            path: "Cardputer Bridge",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}

private func localUSBSerialPorts() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    let paths = names.compactMap { name -> String? in
        guard name.hasPrefix("cu.usbmodem") || name.hasPrefix("cu.usbserial") else {
            return nil
        }
        return "/dev/\(name)"
    }
    return USBSerialPortCatalog.canonicalPorts(from: paths.joined(separator: "\n"))
}

private func discoverSinglePort(using espflash: URL) throws -> String {
    let output = try run(
        espflash,
        ["list-ports", "--name-only", "--skip-update-check"]
    )
    let ports = USBSerialPortCatalog.canonicalPorts(from: output)
    guard !ports.isEmpty else { throw UpdateFailure.deviceNotFound }
    guard ports.count == 1 else { throw UpdateFailure.multipleDevices }
    return ports[0]
}

private func firmwareIsRunning(at port: String) -> Bool {
    let descriptor = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    let request = Array("status\n".utf8)
    _ = request.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }

    var received = Data()
    let deadline = Date().addingTimeInterval(1.5)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            received.append(buffer, count: count)
            if FirmwareBootEvidence.confirmsRunningFirmware(
                String(decoding: received, as: UTF8.self)
            ) {
                return true
            }
        }
        usleep(50_000)
    }
    return false
}

private enum EspflashTool {
    static func prepare() async throws -> URL {
        #if arch(arm64)
        let archiveName = "espflash-aarch64-apple-darwin.zip"
        let expectedSHA = "6614ff70e523a6bce5f4ccc6459b77275f5e7e900429004bb7eec463c95db28a"
        #else
        let archiveName = "espflash-x86_64-apple-darwin.zip"
        let expectedSHA = "3c5cb664742d883e4304d4fc611fc875b27a8f8d7d105d22da2f615eb36888a0"
        #endif
        let root = try USBFirmwarePackage.applicationSupportRoot()
            .appending(path: "tools/espflash/4.5.0", directoryHint: .isDirectory)
        let executable = root.appending(path: "espflash")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = URL(
            string: "https://github.com/esp-rs/espflash/releases/download/v4.5.0/\(archiveName)"
        )!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              SHA256.hash(data: data).hex == expectedSHA else {
            throw UpdateFailure.helperIntegrity
        }
        let archive = root.appending(path: "espflash.zip")
        try data.write(to: archive, options: .atomic)
        _ = try run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            ["-x", "-k", archive.path, root.path]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateFailure.helperIntegrity
        }
        return executable
    }
}

@discardableResult
private func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    // Drain while the child is alive; waiting first can deadlock when a
    // verbose flasher fills the pipe buffer.
    let combined = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: combined, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        let detail = text.isEmpty ? "exit \(process.terminationStatus)" : text
        throw UpdateFailure.flashFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return text
}

private extension SHA256.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
