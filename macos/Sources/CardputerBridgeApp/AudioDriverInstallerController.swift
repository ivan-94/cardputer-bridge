import Combine
import Foundation

@MainActor
final class AudioDriverInstallerController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case installing
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase

    private let fileManager = FileManager.default
    private let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"

    init() {
        phase = FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"
        ) ? .installed : .idle
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: installedDriverPath)
    }

    func refresh() {
        if isInstalled, phase != .installing {
            phase = .installed
        } else if !isInstalled, phase == .installed {
            phase = .idle
        }
    }

    func install() async -> Bool {
        guard phase != .installing else { return false }
        guard let helper = Bundle.main.url(
            forResource: "install-bundled-audio-driver",
            withExtension: "sh",
            subdirectory: "AudioInstaller"
        ) else {
            phase = .failed("安装包不完整：缺少系统麦克风安装器。")
            return false
        }

        phase = .installing
        let helperPath = helper.path
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPrivilegedHelper(at: helperPath)
        }.value

        if result.exitCode == 0 {
            phase = .installed
            return true
        }
        let detail = result.standardError.isEmpty
            ? (result.standardOutput.isEmpty ? "安装已取消或未能完成。" : result.standardOutput)
            : result.standardError
        phase = .failed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        return false
    }

    nonisolated private static func runPrivilegedHelper(
        at helperPath: String
    ) -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "on run argv",
            "-e",
            "do shell script \"/bin/zsh \" & quoted form of (item 1 of argv) with administrator privileges",
            "-e",
            "end run",
            "--",
            helperPath,
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        return (
            process.terminationStatus,
            String(data: standardOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
