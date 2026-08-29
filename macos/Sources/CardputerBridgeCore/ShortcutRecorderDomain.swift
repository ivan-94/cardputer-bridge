import Foundation

public struct HIDKeyDescriptor: Hashable, Identifiable, Sendable {
    public let usage: UInt8
    public let name: String

    public var id: UInt8 { usage }

    public init(usage: UInt8, name: String) {
        self.usage = usage
        self.name = name
    }
}

public struct ShortcutCaptureResult: Equatable, Sendable {
    public let usage: UInt8
    public let modifiers: UInt8

    public init(usage: UInt8, modifiers: UInt8) {
        self.usage = usage
        self.modifiers = modifiers
    }
}

public struct ShortcutCaptureState: Equatable, Sendable {
    public private(set) var pressedModifiers: UInt8 = 0
    public private(set) var observedModifiers: UInt8 = 0
    public private(set) var primaryKeyCode: UInt16?
    public private(set) var pendingResult: ShortcutCaptureResult?

    public init() {}

    public mutating func modifierTransition(macKeyCode: UInt16) -> ShortcutCaptureResult? {
        guard let bit = ShortcutRecorderDomain.modifierBit(
            forMacKeyCode: macKeyCode
        ) else { return nil }
        if pressedModifiers & bit == 0 {
            pressedModifiers |= bit
            observedModifiers |= bit
        } else {
            pressedModifiers &= ~bit
        }
        return finishIfReleased()
    }

    public mutating func primaryDown(
        macKeyCode: UInt16,
        usage: UInt8
    ) {
        guard primaryKeyCode == nil else { return }
        primaryKeyCode = macKeyCode
        pendingResult = ShortcutCaptureResult(
            usage: usage,
            modifiers: observedModifiers | pressedModifiers
        )
    }

    public mutating func primaryUp(macKeyCode: UInt16) -> ShortcutCaptureResult? {
        guard primaryKeyCode == macKeyCode else { return nil }
        primaryKeyCode = nil
        return finishIfReleased()
    }

    private mutating func finishIfReleased() -> ShortcutCaptureResult? {
        guard pressedModifiers == 0, primaryKeyCode == nil else { return nil }
        let result = pendingResult ?? (
            observedModifiers == 0
                ? nil
                : ShortcutCaptureResult(usage: 0, modifiers: observedModifiers)
        )
        pendingResult = nil
        observedModifiers = 0
        return result
    }
}

public enum ShortcutRecorderDomain {
    public static let allKeys: [HIDKeyDescriptor] = {
        var keys: [HIDKeyDescriptor] = []
        for index in 0..<26 {
            keys.append(.init(
                usage: UInt8(0x04 + index),
                name: String(UnicodeScalar(65 + index)!)
            ))
        }
        for index in 0..<9 {
            keys.append(.init(
                usage: UInt8(0x1e + index),
                name: String(index + 1)
            ))
        }
        keys.append(.init(usage: 0x27, name: "0"))
        keys.append(contentsOf: [
            .init(usage: 0x28, name: "Return"),
            .init(usage: 0x29, name: "Esc"),
            .init(usage: 0x2a, name: "Delete"),
            .init(usage: 0x2b, name: "Tab"),
            .init(usage: 0x2c, name: "Space"),
            .init(usage: 0x2d, name: "-"),
            .init(usage: 0x2e, name: "="),
            .init(usage: 0x2f, name: "["),
            .init(usage: 0x30, name: "]"),
            .init(usage: 0x31, name: "\\"),
            .init(usage: 0x33, name: ";"),
            .init(usage: 0x34, name: "'"),
            .init(usage: 0x35, name: "`"),
            .init(usage: 0x36, name: ","),
            .init(usage: 0x37, name: "."),
            .init(usage: 0x38, name: "/"),
            .init(usage: 0x39, name: "Caps Lock"),
        ])
        for index in 0..<12 {
            keys.append(.init(
                usage: UInt8(0x3a + index),
                name: "F\(index + 1)"
            ))
        }
        keys.append(contentsOf: [
            .init(usage: 0x49, name: "Insert"),
            .init(usage: 0x4a, name: "Home"),
            .init(usage: 0x4b, name: "Page Up"),
            .init(usage: 0x4c, name: "Forward Delete"),
            .init(usage: 0x4d, name: "End"),
            .init(usage: 0x4e, name: "Page Down"),
            .init(usage: 0x4f, name: "→"),
            .init(usage: 0x50, name: "←"),
            .init(usage: 0x51, name: "↓"),
            .init(usage: 0x52, name: "↑"),
            .init(usage: 0x54, name: "Keypad /"),
            .init(usage: 0x55, name: "Keypad *"),
            .init(usage: 0x56, name: "Keypad -"),
            .init(usage: 0x57, name: "Keypad +"),
            .init(usage: 0x58, name: "Keypad Enter"),
        ])
        for index in 1...9 {
            keys.append(.init(
                usage: UInt8(0x58 + index),
                name: "Keypad \(index)"
            ))
        }
        keys.append(contentsOf: [
            .init(usage: 0x62, name: "Keypad 0"),
            .init(usage: 0x63, name: "Keypad ."),
            .init(usage: 0x67, name: "Keypad ="),
        ])
        return keys
    }()

    public static let cardputerTriggerUsages: Set<UInt8> = {
        var usages = Set<UInt8>(0x04...0x27)
        usages.formUnion([
            0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
            0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
            0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41,
            0x42, 0x43, 0x44, 0x45, 0x4c, 0x4f, 0x50, 0x51, 0x52,
        ])
        return usages
    }()

    public static let cardputerTriggers = allKeys.filter {
        cardputerTriggerUsages.contains($0.usage)
    }

    public static func hidUsage(forMacKeyCode keyCode: UInt16) -> UInt8? {
        macKeyCodeToHID[keyCode]
    }

    public static func shouldCancelRecording(forMacKeyCode keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    public static func modifiers(
        control: Bool,
        shift: Bool,
        option: Bool,
        command: Bool
    ) -> UInt8 {
        var value: UInt8 = 0
        if control { value |= 0x01 }
        if shift { value |= 0x02 }
        if option { value |= 0x04 }
        if command { value |= 0x08 }
        return value
    }

    public static func modifierBit(forMacKeyCode keyCode: UInt16) -> UInt8? {
        macModifierKeyCodeToHIDBit[keyCode]
    }

    public static func modifierSymbols(for modifiers: UInt8) -> String {
        var value = ""
        appendModifierPair(to: &value, modifiers: modifiers, left: 0x01, right: 0x10, symbol: "⌃")
        appendModifierPair(to: &value, modifiers: modifiers, left: 0x02, right: 0x20, symbol: "⇧")
        appendModifierPair(to: &value, modifiers: modifiers, left: 0x04, right: 0x40, symbol: "⌥")
        appendModifierPair(to: &value, modifiers: modifiers, left: 0x08, right: 0x80, symbol: "⌘")
        return value
    }

    public static func displayName(for usage: UInt8) -> String {
        allKeys.first(where: { $0.usage == usage })?.name
            ?? String(format: "0x%02X", usage)
    }

    public static func displayValue(usage: UInt8, modifiers: UInt8) -> String {
        modifierSymbols(for: modifiers) + (usage == 0 ? "" : displayName(for: usage))
    }

    public static func triggerDisplayValue(
        includesG0: Bool,
        modifiers: UInt8,
        usage: UInt8
    ) -> String {
        var parts: [String] = []
        if includesG0 { parts.append("G0") }
        let keyboardPart = modifierSymbols(for: modifiers) +
            (usage == 0 ? "" : displayName(for: usage))
        if !keyboardPart.isEmpty { parts.append(keyboardPart) }
        return parts.joined(separator: " + ")
    }

    public static func isCardputerTrigger(usage: UInt8) -> Bool {
        cardputerTriggerUsages.contains(usage)
    }

    private static func appendModifierPair(
        to value: inout String,
        modifiers: UInt8,
        left: UInt8,
        right: UInt8,
        symbol: String
    ) {
        let hasLeft = modifiers & left != 0
        let hasRight = modifiers & right != 0
        if hasLeft && hasRight {
            value += "L\(symbol)R\(symbol)"
        } else if hasLeft {
            value += symbol
        } else if hasRight {
            value += "R\(symbol)"
        }
    }

    private static let macModifierKeyCodeToHIDBit: [UInt16: UInt8] = [
        59: 0x01, 56: 0x02, 58: 0x04, 55: 0x08,
        62: 0x10, 60: 0x20, 61: 0x40, 54: 0x80,
    ]

    private static let macKeyCodeToHID: [UInt16: UInt8] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09,
        5: 0x0a, 4: 0x0b, 34: 0x0c, 38: 0x0d, 40: 0x0e, 37: 0x0f,
        46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15,
        1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1a, 7: 0x1b,
        16: 0x1c, 6: 0x1d,
        18: 0x1e, 19: 0x1f, 20: 0x20, 21: 0x21, 23: 0x22,
        22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        36: 0x28, 53: 0x29, 51: 0x2a, 48: 0x2b, 49: 0x2c,
        27: 0x2d, 24: 0x2e, 33: 0x2f, 30: 0x30, 42: 0x31,
        41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37,
        44: 0x38, 57: 0x39,
        122: 0x3a, 120: 0x3b, 99: 0x3c, 118: 0x3d,
        96: 0x3e, 97: 0x3f, 98: 0x40, 100: 0x41,
        101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
        114: 0x49, 115: 0x4a, 116: 0x4b, 117: 0x4c,
        119: 0x4d, 121: 0x4e, 124: 0x4f, 123: 0x50,
        125: 0x51, 126: 0x52,
        75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58,
        83: 0x59, 84: 0x5a, 85: 0x5b, 86: 0x5c, 87: 0x5d,
        88: 0x5e, 89: 0x5f, 91: 0x60, 92: 0x61, 82: 0x62,
        65: 0x63, 81: 0x67,
    ]
}
