import CardputerBridgeCore
import Foundation

@MainActor
final class ShortcutConfigController: ObservableObject {
    @Published private(set) var configuration: BridgeShortcutConfiguration
    @Published private(set) var fault: String?

    private let storageURL: URL

    init() {
        if let override = ProcessInfo.processInfo.environment[
            "CARDPUTER_BRIDGE_CONFIG_PATH"
        ] {
            storageURL = URL(fileURLWithPath: override)
        } else {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            storageURL = root
                .appendingPathComponent("Cardputer Bridge", isDirectory: true)
                .appendingPathComponent("config.json")
        }
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode(
               BridgeShortcutConfiguration.self,
               from: data
           ),
           (try? decoded.validated()) != nil {
            var migrated = decoded.migratedToCurrentSchema()
            if migrated != decoded {
                migrated.configVersion &+= 1
                migrated.updatedAt = Date()
            }
            configuration = migrated
            if migrated != decoded {
                persist(migrated)
            }
        } else {
            configuration = .defaults
            persist(configuration)
        }
    }

    func addMapping(from learned: ShortcutLearnEvent) {
        guard configuration.mappings.count < 32 else {
            fault = "shortcut_limit_reached"
            return
        }
        guard learned.event == .captured,
              let includesG0 = learned.includesG0,
              let triggerModifiers = learned.modifiers,
              let triggerUsage = learned.usage else {
            fault = "shortcut_learning_incomplete"
            return
        }
        apply { mappings in
            mappings.append(.init(
                triggerUsage: triggerUsage,
                triggerModifiers: triggerModifiers,
                triggerIncludesG0: includesG0,
                modifiers: 0,
                outputUsage: triggerUsage == 0 ? 0x2c : triggerUsage,
                label: "新快捷键",
                isEnabled: false
            ))
        }
    }

    func deleteMapping(id: UUID) {
        apply { $0.removeAll { $0.id == id } }
    }

    func forceNextVersion(after deviceVersion: UInt64) {
        var candidate = configuration
        candidate.configVersion = deviceVersion &+ 1
        candidate.updatedAt = Date()
        do {
            _ = try candidate.validated()
            try persistThrowing(candidate)
            configuration = candidate
            fault = nil
        } catch {
            fault = "shortcut_config_invalid_\(error)"
        }
    }

    func updateMapping(
        id: UUID,
        _ update: (inout BridgeShortcutMapping) -> Void
    ) {
        apply { mappings in
            guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
            update(&mappings[index])
        }
    }

    private func apply(_ update: (inout [BridgeShortcutMapping]) -> Void) {
        var candidate = configuration
        update(&candidate.mappings)
        candidate.configVersion &+= 1
        candidate.updatedAt = Date()
        do {
            _ = try candidate.validated()
            try persistThrowing(candidate)
            configuration = candidate
            fault = nil
        } catch {
            fault = "shortcut_config_invalid_\(error)"
        }
    }

    private func persist(_ value: BridgeShortcutConfiguration) {
        do {
            try persistThrowing(value)
        } catch {
            fault = "shortcut_config_save_failed_\(error.localizedDescription)"
        }
    }

    private func persistThrowing(_ value: BridgeShortcutConfiguration) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: storageURL, options: .atomic)
    }
}
