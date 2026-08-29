import CardputerBridgeCore
import CryptoKit
import Foundation

@MainActor
final class FirmwareUpdateController: ObservableObject {
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

    private let manifestURL = URL(
        string: "https://github.com/ivan-94/cardputer-bridge/releases/latest/download/cardputer-bridge-release.json"
    )!
    private let trustedKeys: [String: Data] = [
        "release-2026-01": Data(
            base64Encoded: "VDJ0X9efoO9FPiqG2n/NaZUPjxaWShlnWPvAtL/JzaA="
        )!
    ]

    func check(identity: DeviceFirmwareIdentity?) {
        guard phase != .checking else { return }
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
                try signed.verify(trustedKeys: trustedKeys)
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
        if bluetooth.startFirmwareOTA(release: release) {
            phase = .ota(progress: 0)
        } else {
            phase = .failed(
                message: "Cardputer 控制通道尚未就绪，请恢复蓝牙连接后重试。"
            )
        }
    }

    func observe(_ event: FirmwareOTAEvent?) {
        guard let event else { return }
        switch event.phase {
        case "downloading":
            phase = .ota(progress: event.progress)
        case "restarting":
            phase = .ota(progress: 100)
        case "failed":
            phase = .failed(message: "Cardputer 无法安装更新（错误 \(event.error)）。当前固件仍可继续启动。")
        default:
            break
        }
    }

    func observeIdentity(_ identity: DeviceFirmwareIdentity?) {
        guard let identity,
              let release,
              identity.firmwareVersion == release.version else { return }
        phase = .complete(version: release.version)
    }

    func installOverUSB() {
        guard let release else { return }
        phase = .downloading
        Task {
            do {
                let package = try await USBFirmwarePackage.prepare(release)
                phase = .flashing(progress: 0)
                try await Task.detached(priority: .userInitiated) {
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
}

private enum UpdateFailure: Error {
    case releaseUnavailable
    case deviceNotFound
    case multipleDevices
    case helperIntegrity
    case artifactIntegrity
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
        var port = try discoverSinglePort()

        // Existing Cardputer Bridge firmware understands this command and can
        // enter ROM download mode without asking the user to hold G0. Unknown
        // or blank devices simply ignore the best-effort write.
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: port)) {
            try? handle.write(contentsOf: Data("reboot bootloader\n".utf8))
            try? handle.close()
            // USB Serial/JTAG normally re-enumerates at the same path, but do
            // not assume that: wait for the one unambiguous device again.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if let rediscovered = try? discoverSinglePort() {
                    port = rediscovered
                    break
                }
            }
        }

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
    }

    private func discoverSinglePort() throws -> String {
        let output = try run(
            espflash,
            ["list-ports", "--name-only", "--skip-update-check"]
        )
        let ports = USBSerialPortCatalog.canonicalPorts(from: output)
        guard !ports.isEmpty else { throw UpdateFailure.deviceNotFound }
        guard ports.count == 1 else { throw UpdateFailure.multipleDevices }
        return ports[0]
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
