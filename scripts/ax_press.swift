#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

func find(
    _ element: AXUIElement,
    identifier: String,
    depth: Int = 0
) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if let current = attribute(element, kAXIdentifierAttribute as CFString) as? String,
       current == identifier {
        return element
    }
    guard let children = attribute(
        element,
        kAXChildrenAttribute as CFString
    ) as? [AXUIElement] else {
        return nil
    }
    for child in children {
        if let match = find(child, identifier: identifier, depth: depth + 1) {
            return match
        }
    }
    return nil
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ax_press.swift BUNDLE_ID ACCESSIBILITY_IDENTIFIER\n", stderr)
    exit(2)
}
guard AXIsProcessTrusted() else {
    fputs("accessibility_not_authorized\n", stderr)
    exit(3)
}

let bundleIdentifier = CommandLine.arguments[1]
let accessibilityIdentifier = CommandLine.arguments[2]
guard let application = NSRunningApplication.runningApplications(
    withBundleIdentifier: bundleIdentifier
).first else {
    fputs("application_not_running\n", stderr)
    exit(4)
}

application.activate(options: [.activateAllWindows])
let root = AXUIElementCreateApplication(application.processIdentifier)
let deadline = Date().addingTimeInterval(5)
repeat {
    if let target = find(root, identifier: accessibilityIdentifier) {
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else {
            fputs("accessibility_press_failed_\(result.rawValue)\n", stderr)
            exit(5)
        }
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
} while Date() < deadline

fputs("accessibility_identifier_not_found_\(accessibilityIdentifier)\n", stderr)
exit(6)
