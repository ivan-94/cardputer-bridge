import CardputerBridgeCore
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct CardputerBridgeApp: App {
    @NSApplicationDelegateAdaptor(CardputerBridgeAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class CardputerBridgeAppDelegate: NSObject, NSApplicationDelegate {
    private let bluetooth = BLEBridgeController()
    private let audio = AudioReceiverController()
    private let shortcuts = ShortcutConfigController()
    private let preferences = AppPreferencesController()
    private let nearbyWiFi = NearbyWiFiController()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimPrimaryApplicationInstance() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.createMainWindow()
            self?.installStatusItem()
        }
    }

    private func claimPrimaryApplicationInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        .filter { $0.processIdentifier != currentPID }
        .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
        guard let existing else { return true }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return false
    }

    private func createMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = BridgeRootView()
            .environmentObject(bluetooth)
            .environmentObject(audio)
            .environmentObject(shortcuts)
            .environmentObject(preferences)
            .environmentObject(nearbyWiFi)
            .frame(minWidth: 920, minHeight: 650)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cardputer Bridge"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 920, height: 650)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "keyboard.badge.ellipsis",
                accessibilityDescription: "Cardputer Bridge"
            )
            button.toolTip = "Cardputer Bridge"
        }
        let menu = NSMenu(title: "Cardputer Bridge")
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let openItem = menu.addItem(withTitle: "打开 Cardputer Bridge", action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(.separator())

        let connection = NSMenuItem(title: menuConnectionStatus, action: nil, keyEquivalent: "")
        connection.image = NSImage(
            systemSymbolName: bluetooth.state.phase == .ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
            accessibilityDescription: nil
        )
        menu.addItem(connection)

        let microphone = NSMenuItem(
            title: bluetooth.micIntent == "live" ? "静音麦克风" : "开启麦克风",
            action: #selector(toggleMicrophoneFromStatusItem),
            keyEquivalent: ""
        )
        microphone.image = NSImage(
            systemSymbolName: bluetooth.micIntent == "live" ? "mic.fill" : "mic.slash",
            accessibilityDescription: nil
        )
        microphone.isEnabled = bluetooth.state.canSendCommand
        microphone.target = self
        menu.addItem(microphone)
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 Cardputer Bridge", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
    }

    private var menuConnectionStatus: String {
        switch bluetooth.state.phase {
        case .ready: "Cardputer 已安全连接"
        case .scanning, .connecting, .discoveringServices, .authenticating: "正在连接 Cardputer…"
        case .blocked, .failed: "Cardputer 连接不可用"
        case .waitingForBluetooth, .deviceFound: "等待 Cardputer"
        }
    }

    @objc private func showMainWindow() {
        createMainWindow()
    }

    @objc private func toggleMicrophoneFromStatusItem() {
        bluetooth.toggleMicrophoneIntent()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

extension CardputerBridgeAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }
}

@MainActor
final class AppPreferencesController: ObservableObject {
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var fault: String?

    init() {
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            fault = nil
        } catch {
            fault = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
    }
}

private struct BridgeRootView: View {
    @EnvironmentObject private var bluetooth: BLEBridgeController
    @EnvironmentObject private var audio: AudioReceiverController
    @EnvironmentObject private var shortcuts: ShortcutConfigController
    @EnvironmentObject private var preferences: AppPreferencesController
    @EnvironmentObject private var nearbyWiFi: NearbyWiFiController
    @Environment(\.openURL) private var openURL
    @AppStorage("cardputerBridge.lastWiFiSSID") private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var isEditingWiFi = false
    @State private var lastOfferedSessionID: UInt64?
    @State private var lastAudioOfferAttemptAt = Date.distantPast
    @State private var lastConfigSyncAttemptAt = Date.distantPast
    @State private var lastObservedDeviceAudioReady = false
    @AppStorage("cardputerBridge.setupCompleted") private var setupCompleted = false
    @State private var setupStep = 0
    @State private var selectedSection: DailySection = .overview
    @State private var diagnosticsExportMessage: String?
    @StateObject private var firmwareUpdate = FirmwareUpdateController()
    @StateObject private var audioDriverInstaller = AudioDriverInstallerController()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(BridgeTheme.primaryText)
        .background(BridgeTheme.background)
        .preferredColorScheme(.dark)
        .groupBoxStyle(BridgeGroupBoxStyle())
        .task {
            bluetooth.start()
            audioDriverInstaller.refresh()
            audio.onAuthenticatedTestFrame = { [weak bluetooth] sessionID in
                Task { @MainActor in
                    bluetooth?.confirmAudioReady(sessionID: sessionID)
                }
            }
            audio.start()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                bluetooth.tickHarnessMicrophone()
                bluetooth.tickHarnessShortcutLearning()
                offerAudioToAlreadyConnectedDeviceIfNeeded()
                syncShortcutConfigurationIfNeeded()
            }
        }
        .onChange(of: bluetooth.deviceStateJSON) {
            if !recoverAudioSessionAfterDeviceRestartIfNeeded() {
                offerAudioToAlreadyConnectedDeviceIfNeeded()
            }
        }
        .onChange(of: bluetooth.state.phase) {
            offerAudioToAlreadyConnectedDeviceIfNeeded()
        }
        .onChange(of: bluetooth.firmwareOTAEvent) {
            firmwareUpdate.observe(bluetooth.firmwareOTAEvent)
        }
        .onChange(of: bluetooth.firmwareIdentity) {
            firmwareUpdate.observeIdentity(bluetooth.firmwareIdentity)
        }
        .onChange(of: audio.offer?.sessionID) {
            offerAudioToAlreadyConnectedDeviceIfNeeded()
        }
        .onChange(of: bluetooth.deviceConfigVersion) {
            syncShortcutConfigurationIfNeeded()
        }
        .onChange(of: shortcuts.configuration.configVersion) {
            syncShortcutConfigurationIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.red.gradient, in: RoundedRectangle(cornerRadius: 7))
            Text("Cardputer Bridge")
                .font(.headline)
            Spacer()
            if !setupCompleted {
                Label("首次设置", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BridgeTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(BridgeTheme.surfaceRaised, in: Capsule())
            }
            statusBadge
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(BridgeTheme.surface)
    }

    private var content: some View {
        Group {
            if setupCompleted {
                dashboardContent
            } else {
                onboardingContent
            }
        }
    }

    private var dashboardContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DailySection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(
                                selectedSection == section ? BridgeTheme.surfaceRaised : .clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("navigation-\(section.rawValue)")
                }
                Spacer()
            }
            .padding(16)
            .frame(width: 196)
            .background(BridgeTheme.surface)

            Divider().overlay(BridgeTheme.border)
            dailySectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var dailySectionContent: some View {
        switch selectedSection {
        case .overview:
            overviewContent
        case .shortcuts:
            simplePage(title: "快捷键", detail: "把 Cardputer 的任意实体按键或组合键映射为 Mac 快捷键。") {
                shortcutSetup
            }
        case .microphone:
            simplePage(title: "麦克风", detail: "控制 Cardputer Microphone 在 macOS 中的工作方式。") {
                audioSetup
            }
        case .device:
            simplePage(title: "设备与连接", detail: "分别查看键盘、控制通道、Wi-Fi 与音频状态") {
                deviceConnectionDetails
            }
        case .settings:
            simplePage(title: "设置", detail: "决定 Cardputer Bridge 如何随这台 Mac 工作。") {
                settingsContent
            }
        case .about:
            simplePage(title: "关于", detail: "让 Cardputer 成为这台 Mac 的键盘和麦克风。") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cardputer Bridge")
                        .font(.title2.bold())
                    Text("快捷键通过蓝牙发送，麦克风声音通过当前局域网传输。")
                        .foregroundStyle(BridgeTheme.secondaryText)
                    Text("麦克风默认静音；控制链路失联后设备会自动关闭采集。")
                        .foregroundStyle(BridgeTheme.secondaryText)
                    Divider()
                    HStack {
                        Button {
                            exportDiagnostics()
                        } label: {
                            Label("导出诊断报告", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        Text("不包含密码、密钥、原始音频或普通键入内容。")
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                    }
                    if let diagnosticsExportMessage {
                        Text(diagnosticsExportMessage)
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                    }
                }
                .padding(20)
                .bridgePanel()
            }
        }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("概览")
                        .font(.system(size: 30, weight: .bold))
                    Text("Cardputer 现在是这台 Mac 的键盘和麦克风。")
                        .foregroundStyle(BridgeTheme.secondaryText)
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            Text("C")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(BridgeTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Cardputer-ADV")
                                    .font(.title3.weight(.semibold))
                                Text(systemInputSummary)
                                    .foregroundStyle(BridgeTheme.secondaryText)
                            }
                        }

                        HStack(spacing: 18) {
                            overviewStatus("键盘", value: keyboardStatus, detail: "Bluetooth LE HID")
                            overviewStatus("麦克风", value: systemMicrophonePipelineReady ? "系统可用" : "未就绪", detail: "\(currentWiFiName) · 约 60 ms 缓冲")
                            overviewStatus("快捷键", value: shortcutConfigurationIsSynced ? "已同步" : "待同步", detail: "以 Mac 设置为准")
                            overviewStatus("设备", value: deviceBatteryText, detail: deviceSignalText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    CardputerProductImage()
                        .frame(width: 238, height: 143)
                }
                .padding(22)
                .bridgePanel(border: BridgeTheme.success.opacity(0.25))

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("系统麦克风")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BridgeTheme.secondaryText)
                                Text("Cardputer Microphone").font(.headline)
                            }
                            Spacer()
                            Text(bluetooth.micIntent == "live" ? "正在传音" : "静音")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(bluetooth.micIntent == "live" ? BridgeTheme.success : BridgeTheme.warning)
                        }
                        AudioLevelBars(level: audio.metrics.signalLevel, isActive: bluetooth.micIntent == "live")
                            .padding(.vertical, 8)
                        Text(bluetooth.micIntent == "live" ? "声音正通过局域网进入 macOS。" : "已经连接，但不会发送你的声音。")
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                        actionButton
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                    .bridgePanel()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("快捷键")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BridgeTheme.secondaryText)
                                Text("辅助快捷键盘").font(.headline)
                            }
                            Spacer()
                            Image(systemName: "command")
                                .font(.title2)
                                .foregroundStyle(BridgeTheme.secondaryText)
                        }
                        HStack(spacing: 7) {
                            shortcutKey(recentShortcutTrigger)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(BridgeTheme.secondaryText)
                            shortcutKey(recentShortcutOutput)
                        }
                        .padding(.vertical, 8)
                        Text("实体按键或组合键命中映射后，会直接向 macOS 发送设定的快捷键。")
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                        Button("管理快捷键") { selectedSection = .shortcuts }
                            .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                    .bridgePanel()
                }

                HStack(spacing: 12) {
                    Image(systemName: bothSystemInputsReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(bothSystemInputsReady ? BridgeTheme.success : BridgeTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bothSystemInputsReady ? "两种系统输入均可用" : "系统输入尚未全部就绪")
                            .font(.headline)
                        Text(systemIntegrationDetail)
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                    }
                    Spacer()
                    Button("查看连接详情") { selectedSection = .device }
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .bridgePanel()

                if bluetooth.state.phase == .authenticating {
                    Label(
                        "正在恢复加密控制通道。首次连接时 macOS 可能要求配对；已配对设备会直接继续。",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.orange)
                }

                if let fault = bluetooth.state.fault ?? bluetooth.commandFault {
                    faultView(fault)
                }

                if let audioFault = audio.fault {
                    faultView(audioFault)
                }

                Spacer()
            }
            .frame(maxWidth: 800)
            .padding(32)
        }
    }

    private func overviewStatus(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(BridgeTheme.secondaryText)
            Text(value).font(.callout.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(BridgeTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutKey(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                LinearGradient(
                    colors: [BridgeTheme.surfaceRaised, BridgeTheme.surface],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(BridgeTheme.border))
    }

    private var recentShortcutTrigger: String {
        guard let event = bluetooth.lastShortcutEvent else { return "尚无" }
        return ShortcutRecorderDomain.triggerDisplayValue(
            includesG0: event.includesG0,
            modifiers: event.triggerModifiers,
            usage: event.triggerUsage
        )
    }

    private var recentShortcutOutput: String {
        guard let event = bluetooth.lastShortcutEvent else { return "等待触发" }
        return ShortcutRecorderDomain.displayValue(
            usage: event.outputUsage,
            modifiers: event.outputModifiers
        )
    }

    private var deviceBatteryText: String {
        guard let percent = bluetooth.deviceTelemetry?.batteryPercent,
              percent >= 0 else { return "电量 --" }
        return "电量 \(percent)%"
    }

    private var deviceSignalText: String {
        guard let rssi = bluetooth.deviceTelemetry?.wifiRSSI,
              rssi < 0 else { return "Wi-Fi 信号待更新" }
        switch rssi {
        case -55...0: return "Wi-Fi 信号优秀"
        case -67 ..< -55: return "Wi-Fi 信号良好"
        case -75 ..< -67: return "Wi-Fi 信号一般"
        default: return "Wi-Fi 信号较弱"
        }
    }

    private func exportDiagnostics() {
        let report = CardputerDiagnosticsReport(
            generatedAt: Date(),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            blePhase: bluetooth.state.phase.rawValue,
            microphoneIntent: bluetooth.micIntent,
            audioStatus: audio.status.rawValue,
            systemMicrophoneReady: audio.systemMicrophoneReady,
            configurationSynced: shortcutConfigurationIsSynced,
            wifiConnected: deviceWiFiConnected,
            batteryPercent: bluetooth.deviceTelemetry?.batteryPercent,
            wifiRSSI: bluetooth.deviceTelemetry?.wifiRSSI,
            acceptedPackets: audio.metrics.acceptedPackets,
            missingPackets: audio.metrics.missingPackets,
            duplicateOrLatePackets: audio.metrics.duplicateOrLatePackets,
            controlFault: bluetooth.state.fault ?? bluetooth.commandFault,
            audioFault: audio.fault
        )
        do {
            let panel = NSSavePanel()
            panel.title = "导出 Cardputer Bridge 诊断报告"
            panel.nameFieldStringValue = "cardputer-bridge-diagnostics.json"
            guard panel.runModal() == .OK, let destination = panel.url else {
                return
            }
            try report.encodedJSON().write(to: destination, options: .atomic)
            diagnosticsExportMessage = "诊断报告已导出。"
        } catch {
            diagnosticsExportMessage = "导出失败，请重试。"
        }
    }

    private func simplePage<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    Text(detail).foregroundStyle(BridgeTheme.secondaryText)
                }
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
        }
    }

    private func systemMicrophoneStatusCard(identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(systemMicrophoneTitle, systemImage: systemMicrophoneIcon)
                .font(.headline)
                .foregroundStyle(systemMicrophoneColor)
            Text(systemMicrophoneDetail)
                .foregroundStyle(BridgeTheme.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bridgePanel(border: systemMicrophoneColor.opacity(0.35))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(systemMicrophoneTitle)
        .accessibilityValue(systemMicrophoneDetail)
    }

    private var systemMicrophoneTitle: String {
        if audio.systemMicrophoneReady, audio.fault != nil {
            return "Cardputer Microphone 已注册，音频链路异常"
        }
        if audio.systemMicrophoneReady {
            return "Cardputer Microphone 已注册"
        }
        if audio.fault != nil {
            return "系统麦克风连接失败"
        }
        return "正在连接系统麦克风"
    }

    private var systemMicrophoneDetail: String {
        if let fault = audio.fault {
            return "音频桥接尚未就绪：\(fault)"
        }
        if audio.systemMicrophoneReady {
            return "Core Audio 已枚举系统输入且音频桥接就绪；可在录音、会议或语音 App 中选择 Cardputer Microphone。"
        }
        return "正在等待本机音频桥接就绪。完成前 Cardputer 保持静音，不会上传声音。"
    }

    private var systemMicrophoneIcon: String {
        if audio.fault != nil {
            return "exclamationmark.triangle.fill"
        }
        if audio.systemMicrophoneReady {
            return "checkmark.circle.fill"
        }
        return "clock.badge"
    }

    private var systemMicrophoneColor: Color {
        if audio.fault != nil {
            return BridgeTheme.accent
        }
        if audio.systemMicrophoneReady {
            return BridgeTheme.success
        }
        return BridgeTheme.warning
    }

    private var systemMicrophonePipelineReady: Bool {
        audio.systemMicrophoneReady &&
            audio.offer != nil &&
            audio.status != .failed &&
            audio.fault == nil
    }

    private var deviceConnectionDetails: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            capability("BLE 键盘", value: keyboardStatus, icon: "keyboard")
            capability("GATT 控制", value: controlStatus, icon: "lock.shield")
            capability("Wi-Fi", value: deviceWiFiConnected ? "已连接" : "未连接", icon: "wifi")
            capability("音频会话", value: audioStatus, icon: "waveform")
            capability("系统麦克风", value: systemMicrophonePipelineReady ? "已就绪" : "未就绪", icon: "mic")
        }
        .padding(20)
        .bridgePanel()
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "power")
                    .font(.title3)
                    .foregroundStyle(BridgeTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(BridgeTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录时自动启动").font(.headline)
                    Text(preferences.launchAtLoginRequiresApproval ? "请在“系统设置 → 通用 → 登录项”中允许 Cardputer Bridge。" : "登录这台 Mac 后自动恢复键盘、控制通道与系统麦克风。")
                        .font(.caption)
                        .foregroundStyle(BridgeTheme.secondaryText)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { preferences.launchAtLoginEnabled },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .accessibilityLabel("登录时自动启动")
            }
            .padding(18)

            Divider().overlay(BridgeTheme.border)

            HStack(spacing: 16) {
                Image(systemName: "menubar.rectangle")
                    .font(.title3)
                    .foregroundStyle(BridgeTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(BridgeTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("菜单栏控制").font(.headline)
                    Text("关闭主窗口后仍保持运行；可从菜单栏重新打开 App 或控制麦克风。")
                        .font(.caption)
                        .foregroundStyle(BridgeTheme.secondaryText)
                }
                Spacer()
                Label("已启用", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BridgeTheme.success)
            }
            .padding(18)
            }
            .bridgePanel()
            firmwareUpdateCard
        }
        .overlay(alignment: .bottomLeading) {
            if let fault = preferences.fault {
                Text(fault)
                    .font(.caption)
                    .foregroundStyle(BridgeTheme.accent)
                    .padding(18)
                    .offset(y: 42)
            }
        }
    }

    private var firmwareUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.title2)
                    .foregroundStyle(BridgeTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        BridgeTheme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cardputer 固件").font(.headline)
                    Text(firmwareVersionSummary)
                        .font(.caption)
                        .foregroundStyle(BridgeTheme.secondaryText)
                }
                Spacer()
                firmwareUpdateAction
            }
            if let progress = firmwareProgress {
                ProgressView(value: Double(progress), total: 100)
                    .tint(BridgeTheme.accent)
            }
        }
        .padding(18)
        .bridgePanel()
    }

    private var firmwareVersionSummary: String {
        let current = bluetooth.firmwareIdentity?.firmwareVersion ?? "旧版或未识别"
        switch firmwareUpdate.phase {
        case .idle:
            return "当前 \(current) · 可检查新版本"
        case .checking:
            return "正在验证发布清单…"
        case .available(.upToDate):
            return "当前 \(current) · 已是最新版本"
        case .available(.usbMigrationRequired(let target)):
            return "当前 \(current) · 首次升级到 \(target) 需要 USB"
        case .available(.otaAvailable(_, let target)):
            return "发现 \(target) · 可通过 Wi-Fi 安装"
        case .available(.incompatible(let reason)):
            return "这个更新不适用于当前设备：\(reason)"
        case .downloading:
            return "正在下载并校验固件…"
        case .flashing:
            return "正在通过 USB 安装，请勿断开设备"
        case .ota:
            return "Cardputer 正在下载并切换安全更新槽"
        case .complete(let version):
            return "已安装 \(version)"
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var firmwareUpdateAction: some View {
        switch firmwareUpdate.phase {
        case .idle, .failed:
            Button("检查更新") {
                firmwareUpdate.check(identity: bluetooth.firmwareIdentity)
            }
            .buttonStyle(.borderedProminent)
        case .available(.usbMigrationRequired):
            Button("通过 USB 安装") {
                firmwareUpdate.installOverUSB()
            }
            .buttonStyle(.borderedProminent)
        case .available(.otaAvailable):
            Button("通过 Wi-Fi 更新") {
                firmwareUpdate.beginOTA(using: bluetooth)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!bluetooth.state.canSendCommand)
        case .available(.upToDate), .available(.incompatible), .complete:
            Button("再次检查") {
                firmwareUpdate.check(identity: bluetooth.firmwareIdentity)
            }
            .buttonStyle(.bordered)
        case .checking, .downloading, .flashing, .ota:
            ProgressView().controlSize(.small)
        }
    }

    private var firmwareProgress: Int? {
        switch firmwareUpdate.phase {
        case .flashing(let progress), .ota(let progress): progress
        default: nil
        }
    }

    private var onboardingContent: some View {
        VStack(spacing: 0) {
            onboardingStepBar
            Divider().overlay(BridgeTheme.border)

            ScrollView {
                VStack(spacing: 22) {
                    onboardingIllustration
                    onboardingCopy
                    onboardingState
                    onboardingActions
                    Label(
                        "默认静音；控制链路失联会立即停止上传声音。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(BridgeTheme.secondaryText)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 40)
                .padding(.vertical, 26)
            }
        }
    }

    private var onboardingStepBar: some View {
        HStack(spacing: 18) {
            if setupStep > 0 {
                Button {
                    setupStep -= 1
                } label: {
                    Label("上一步", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BridgeTheme.secondaryText)
            }

            Text("首次设置 · \(setupStep + 1)/6")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(BridgeTheme.secondaryText)
            Text(onboardingTitle)
                .font(.headline)
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(index < setupStep ? BridgeTheme.success :
                              index == setupStep ? BridgeTheme.accent : BridgeTheme.border)
                        .frame(width: 34, height: 4)
                }
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 32)
        .frame(height: 64)
    }

    @ViewBuilder
    private var onboardingIllustration: some View {
        switch setupStep {
        case 0:
            HStack(spacing: 34) {
                CardputerProductImage()
                Image(systemName: "arrow.right")
                    .foregroundStyle(BridgeTheme.accent)
                VStack(spacing: 12) {
                    onboardingCapability("系统键盘", icon: "command")
                    onboardingCapability("Wi-Fi 麦克风", icon: "mic")
                }
            }
            .padding(24)
            .bridgePanel()
        case 1:
            onboardingSymbol("antenna.radiowaves.left.and.right")
        case 2:
            onboardingSymbol("lock.shield")
        case 3:
            onboardingSymbol("wifi")
        case 4:
            onboardingSymbol("waveform.badge.mic")
        default:
            onboardingSymbol("checkmark")
        }
    }

    private var onboardingCopy: some View {
        VStack(spacing: 8) {
            Text(onboardingHeadline)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Text(onboardingDetail)
                .foregroundStyle(BridgeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
        }
    }

    @ViewBuilder
    private var onboardingState: some View {
        switch setupStep {
        case 0:
            firmwareUpdateCard
        case 1, 2:
            HStack(spacing: 12) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bluetooth.state.device?.name ?? "Cardputer-ADV")
                        .font(.headline)
                    Text(statusText).foregroundStyle(BridgeTheme.secondaryText)
                }
                Spacer()
                if bluetooth.state.phase == .ready {
                    Label("加密通道就绪", systemImage: "lock.fill")
                        .foregroundStyle(BridgeTheme.success)
                }
            }
            .padding(18)
            .bridgePanel()
        case 3:
            if deviceWiFiConnected {
                Label("Cardputer 已接入 Wi-Fi", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BridgeTheme.success)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bridgePanel()
            } else {
                VStack(spacing: 12) {
                    TextField("2.4GHz Wi-Fi 名称", text: $wifiSSID)
                    SecureField("Wi-Fi 密码", text: $wifiPassword)
                }
                .textFieldStyle(.roundedBorder)
                .padding(18)
                .bridgePanel()
            }
        case 4:
            VStack(spacing: 12) {
                systemMicrophoneStatusCard(identifier: "onboarding-system-microphone-status")
                if case .failed(let message) = audioDriverInstaller.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(BridgeTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case 5:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                onboardingResult("BLE 键盘", keyboardStatus, status: bluetooth.hidConnected)
                onboardingResult("快捷键配置", configSyncText, status: bluetooth.deviceConfigVersion == shortcuts.configuration.configVersion)
                onboardingResult("Wi-Fi 音频", audioStatus, status: audio.status == .receiving || audio.status == .listening)
                onboardingResult("系统麦克风", systemMicrophonePipelineReady ? "已注册" : "未就绪", status: systemMicrophonePipelineReady)
            }
            .padding(18)
            .bridgePanel()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var onboardingActions: some View {
        if setupStep == 1 && bluetooth.state.phase != .ready {
            actionButton
        } else if setupStep == 3 && !deviceWiFiConnected {
            Button("连接并继续") {
                guard let offer = audio.offer else { return }
                bluetooth.provisionWiFiAndStartAudio(ssid: wifiSSID, password: wifiPassword, offer: offer)
            }
            .buttonStyle(BridgePrimaryButtonStyle())
            .disabled(wifiSSID.isEmpty || wifiPassword.count < 8 || audio.offer == nil)
        } else if setupStep == 4 {
            if systemMicrophonePipelineReady {
                Button("继续") { setupStep = 5 }
                    .buttonStyle(BridgePrimaryButtonStyle())
            } else {
                Button(audioDriverInstaller.phase == .installing ? "正在安装…" : "安装系统麦克风") {
                    Task {
                        guard await audioDriverInstaller.install() else { return }
                        for _ in 0..<8 where !audio.systemMicrophoneReady {
                            try? await Task.sleep(for: .milliseconds(750))
                            audio.refreshSystemMicrophone()
                        }
                    }
                }
                .buttonStyle(BridgePrimaryButtonStyle())
                .disabled(audioDriverInstaller.phase == .installing)
            }
        } else if setupStep == 5 {
            Button("进入 Cardputer Bridge") { setupCompleted = true }
                .buttonStyle(BridgePrimaryButtonStyle())
        } else {
            Button(setupStep == 0 ? "开始设置" : "继续") {
                setupStep = min(5, setupStep + 1)
            }
            .buttonStyle(BridgePrimaryButtonStyle())
            .disabled((setupStep == 2 && bluetooth.state.phase != .ready) ||
                      (setupStep == 3 && !deviceWiFiConnected))
        }
    }

    private var deviceWiFiConnected: Bool {
        bluetooth.deviceStateJSON.contains("\"wifi\":\"connected\"")
    }

    private var onboardingTitle: String {
        ["欢迎", "发现设备", "安全配对", "接入 Wi-Fi", "系统麦克风", "完成"][setupStep]
    }

    private var onboardingHeadline: String {
        switch setupStep {
        case 0: "把 Cardputer 连接到这台 Mac"
        case 1: "找到你的 Cardputer"
        case 2: "建立安全控制通道"
        case 3: "让声音进入局域网"
        case 4: "注册系统麦克风"
        default: "基础链路已经就绪"
        }
    }

    private var onboardingDetail: String {
        switch setupStep {
        case 0: "先在 Mac 上检查并安装正式固件，然后它会成为 BLE 键盘和局域网麦克风。已安装过的设备可直接继续。"
        case 1: "保持 Cardputer 开机；App 会发现或恢复此前绑定的设备。"
        case 2: "控制服务只接受已加密、已认证的连接。已有 bond 会直接恢复，不会重复显示配对码。"
        case 3: "Wi-Fi 承载实时音频；BLE 继续负责配网、静音与心跳控制。"
        case 4: "点击一次安装随 App 附带的系统麦克风驱动；macOS 会显示标准管理员授权框。安装完成后，App 会确认 Cardputer Microphone 已发布。"
        default: "你现在可以使用 BLE 键盘、同步 G0 快捷键，并在系统 App 中选择 Cardputer Microphone。"
        }
    }

    private func onboardingCapability(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(width: 170, height: 56)
            .background(BridgeTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BridgeTheme.border))
    }

    private func onboardingSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 42, weight: .medium))
            .foregroundStyle(BridgeTheme.accent)
            .frame(width: 92, height: 92)
            .background(BridgeTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(BridgeTheme.border))
    }

    private func onboardingResult(_ label: String, _ value: String, status: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: status ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status ? BridgeTheme.success : BridgeTheme.secondaryText)
            Text(value).font(.caption).foregroundStyle(BridgeTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wifi")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(deviceWiFiConnected ? BridgeTheme.success : BridgeTheme.warning)
                    .frame(width: 42, height: 42)
                    .background(BridgeTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(deviceWiFiConnected ? currentWiFiName : "尚未连接 Wi-Fi")
                        .font(.headline)
                    Text(deviceWiFiConnected ? "Cardputer 的音频正在通过这个局域网传输" : "连接一个 2.4 GHz 网络以启用无线麦克风")
                        .foregroundStyle(BridgeTheme.secondaryText)
                }
                Spacer()
                if deviceWiFiConnected {
                    Button(isEditingWiFi ? "取消" : "更换网络") {
                        if !isEditingWiFi, wifiSSID.isEmpty {
                            wifiSSID = currentWiFiName
                        }
                        isEditingWiFi.toggle()
                        wifiPassword = ""
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !deviceWiFiConnected || isEditingWiFi {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if nearbyWiFi.networks.isEmpty {
                            Text("选择附近的 2.4 GHz 网络，或手动输入名称。")
                                .font(.caption)
                                .foregroundStyle(BridgeTheme.secondaryText)
                        } else {
                            Menu {
                                ForEach(nearbyWiFi.networks) { network in
                                    Button {
                                        wifiSSID = network.ssid
                                    } label: {
                                        Label(
                                            "\(network.ssid) · 信道 \(network.channel)",
                                            systemImage: network.signalSymbol
                                        )
                                    }
                                }
                            } label: {
                                Label("选择附近网络", systemImage: "wifi")
                            }
                            .menuStyle(.borderlessButton)
                        }
                        Spacer()
                        Button {
                            nearbyWiFi.scan()
                        } label: {
                            if nearbyWiFi.isScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(nearbyWiFi.networks.isEmpty ? "扫描" : "重新扫描", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(nearbyWiFi.isScanning)
                    }

                    TextField("2.4 GHz Wi-Fi 名称", text: $wifiSSID)
                        .accessibilityIdentifier("wifi-ssid-input")
                    SecureField("Wi-Fi 密码", text: $wifiPassword)
                        .accessibilityIdentifier("wifi-password-input")
                    HStack {
                        Text("凭据只发送给当前安全配对的 Cardputer。")
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.secondaryText)
                        Spacer()
                        Button("连接") {
                            provisionCurrentWiFi()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            wifiSSID.isEmpty || wifiPassword.count < 8 || audio.offer == nil
                        )
                    }
                    if let fault = nearbyWiFi.fault {
                        Text(fault)
                            .font(.caption)
                            .foregroundStyle(BridgeTheme.warning)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(14)
                .background(BridgeTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BridgeTheme.border))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("输入电平")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BridgeTheme.secondaryText)
                    Spacer()
                    Text(bluetooth.micIntent == "live" ? "正在传音" : "已静音")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bluetooth.micIntent == "live" ? BridgeTheme.success : BridgeTheme.warning)
                }
                AudioLevelBars(level: audio.metrics.signalLevel, isActive: bluetooth.micIntent == "live")
            }
            .padding(14)
            .background(BridgeTheme.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .bridgePanel()
    }

    private var shortcutSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                HStack {
                    Text("Cardputer 按键").frame(maxWidth: .infinity, alignment: .leading)
                    Text("发送给 Mac").frame(maxWidth: .infinity, alignment: .leading)
                    Text("名称").frame(width: 150, alignment: .leading)
                    Text("启用").frame(width: 46)
                    Color.clear.frame(width: 24)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(BridgeTheme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(BridgeTheme.background)

                ForEach(shortcuts.configuration.mappings) { mapping in
                    Divider().overlay(BridgeTheme.border)
                    ShortcutMappingRow(mapping: mapping)
                        .environmentObject(shortcuts)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BridgeTheme.border))

            HStack {
                AddShortcutMappingButton()
                .disabled(shortcuts.configuration.mappings.count >= 32)
                Spacer()
                Button("同步到 Cardputer") {
                    bluetooth.syncShortcutConfiguration(shortcuts.configuration)
                }
                .buttonStyle(.borderedProminent)
                .disabled(shortcutConfigurationIsSynced)
            }

            if let deviceVersion = bluetooth.deviceConfigVersion,
               deviceVersion > shortcuts.configuration.configVersion {
                HStack(spacing: 10) {
                    Label("设备上的配置版本较新。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(BridgeTheme.warning)
                    Spacer()
                    Button("以 Mac 配置覆盖设备") {
                        shortcuts.forceNextVersion(after: deviceVersion)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }
        }
    }

    private var configSyncText: String {
        guard let deviceVersion = bluetooth.deviceConfigVersion else {
            return "等待设备配置"
        }
        if deviceVersion == shortcuts.configuration.configVersion {
            return "已同步"
        }
        if deviceVersion > shortcuts.configuration.configVersion {
            return "设备配置较新"
        }
        return "有修改待同步"
    }

    private var configSyncColor: Color {
        bluetooth.deviceConfigVersion == shortcuts.configuration.configVersion
            ? .green
            : .orange
    }

    private var shortcutConfigurationIsSynced: Bool {
        bluetooth.deviceConfigVersion == shortcuts.configuration.configVersion
    }

    private var currentWiFiName: String {
        bluetooth.currentWiFiSSID ?? (wifiSSID.isEmpty ? "当前 Wi-Fi" : wifiSSID)
    }

    private func provisionCurrentWiFi() {
        guard let offer = audio.offer else { return }
        lastOfferedSessionID = offer.sessionID
        bluetooth.provisionWiFiAndStartAudio(
            ssid: wifiSSID,
            password: wifiPassword,
            offer: offer
        )
        wifiPassword = ""
        isEditingWiFi = false
    }

    private func offerAudioToAlreadyConnectedDeviceIfNeeded() {
        let retryInterval: TimeInterval = 1.5
        let wifiIsConnected = bluetooth.deviceStateJSON.contains(
            "\"wifi\":\"connected\""
        )
        let deviceAudioIsReady = bluetooth.deviceStateJSON.contains(
            "\"audio\":\"ready\""
        )
        if bluetooth.state.phase == .ready,
           AudioSessionRecovery.shouldRotateStaleAuthenticatedSession(
               deviceAudioIsReady: deviceAudioIsReady,
               wifiIsConnected: wifiIsConnected,
               authenticatedPacketCount: audio.metrics.acceptedPackets
           ) {
            // The device rebooted or lost its receiver while this App still
            // holds authenticated packets from the previous UDP session.
            // Rotate before offering so sequence zero never reuses a GCM nonce.
            audio.start()
            lastOfferedSessionID = nil
            lastAudioOfferAttemptAt = .distantPast
            return
        }
        guard AudioSessionRecovery.shouldOfferSession(
            controlIsReady: bluetooth.state.phase == .ready,
            wifiIsConnected: wifiIsConnected,
            authenticatedPacketCount: audio.metrics.acceptedPackets
        ) else {
            return
        }
        // The device can still report `audio:ready` for a UDP session owned by
        // the previous App process. Only an authenticated frame received by
        // this process proves that both endpoints share the current session.
        guard let offer = audio.offer else {
            if audio.status == .stopped || audio.status == .failed {
                audio.start()
            }
            return
        }
        let elapsed = Date().timeIntervalSince(lastAudioOfferAttemptAt)
        if AudioSessionRecovery.shouldRotateFailedOffer(
            currentSessionID: offer.sessionID,
            lastOfferedSessionID: lastOfferedSessionID,
            elapsedSeconds: elapsed,
            retryInterval: retryInterval
        ) {
            // Retrying the same session would reset the device sequence while
            // reusing the AES-GCM nonce space. A retry is a fresh session.
            audio.start()
            lastOfferedSessionID = nil
            lastAudioOfferAttemptAt = .distantPast
            return
        }
        guard lastOfferedSessionID != offer.sessionID || elapsed >= retryInterval else {
            return
        }
        lastAudioOfferAttemptAt = Date()
        lastOfferedSessionID = offer.sessionID
        bluetooth.startAudio(offer: offer)
    }

    @discardableResult
    private func recoverAudioSessionAfterDeviceRestartIfNeeded() -> Bool {
        let currentReady = bluetooth.deviceStateJSON.contains("\"audio\":\"ready\"")
        let wifiConnected = bluetooth.deviceStateJSON.contains(
            "\"wifi\":\"connected\""
        )
        if AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: lastObservedDeviceAudioReady,
            currentDeviceIsReady: currentReady,
            wifiIsConnected: wifiConnected
        ) {
            // A reboot resets the device sequence counter. Reusing the old
            // session would both reject sequence zero and reuse AES-GCM nonces.
            audio.start()
            lastOfferedSessionID = nil
            lastAudioOfferAttemptAt = .distantPast
            lastObservedDeviceAudioReady = currentReady
            return true
        }
        lastObservedDeviceAudioReady = currentReady
        return false
    }

    private func syncShortcutConfigurationIfNeeded() {
        guard bluetooth.state.phase == .ready,
              let deviceVersion = bluetooth.deviceConfigVersion,
              shortcuts.configuration.configVersion > deviceVersion,
              Date().timeIntervalSince(lastConfigSyncAttemptAt) >= 1.5 else {
            return
        }
        lastConfigSyncAttemptAt = Date()
        bluetooth.syncShortcutConfiguration(shortcuts.configuration)
    }

    private var statusBadge: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var actionButton: some View {
        switch bluetooth.state.phase {
        case .deviceFound:
            Button("连接") { bluetooth.connect() }
                .buttonStyle(.borderedProminent)
        case .ready:
            Button(bluetooth.micIntent == "live" ? "静音" : "开启麦克风") {
                bluetooth.toggleMicrophoneIntent()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("microphone-toggle")
            .accessibilityLabel(
                bluetooth.micIntent == "live" ? "静音" : "开启麦克风"
            )
        case .blocked where bluetooth.state.radio == .unauthorized:
            Button("打开隐私设置") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            }
        case .blocked where bluetooth.state.radio == .poweredOff:
            Button("打开蓝牙设置") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            }
        case .failed:
            Button("重新查找") { bluetooth.retry() }
        default:
            EmptyView()
        }
    }

    private func capability(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func faultView(_ fault: String) -> some View {
        Label(faultMessage(fault), systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        bluetooth.state.phase == .ready ? "Cardputer 已连接" : "连接 Cardputer"
    }

    private var detail: String {
        switch bluetooth.state.phase {
        case .ready: "安全控制通道已就绪。BLE 键盘与控制通道使用同一台设备。"
        case .deviceFound: "已发现附近的 Cardputer，连接后由 macOS 完成安全配对。"
        default: "App 会发现 Cardputer Bridge，并建立需要加密认证的控制通道。"
        }
    }

    private var statusText: String {
        switch bluetooth.state.phase {
        case .waitingForBluetooth: "正在初始化"
        case .scanning: "正在查找"
        case .deviceFound: "已发现"
        case .connecting: "正在连接"
        case .discoveringServices: "正在检查协议"
        case .authenticating: "等待安全配对"
        case .ready: "已安全连接"
        case .blocked: "蓝牙不可用"
        case .failed: "连接失败"
        }
    }

    private var statusColor: Color {
        switch bluetooth.state.phase {
        case .ready: .green
        case .deviceFound, .connecting, .discoveringServices, .authenticating: .orange
        case .blocked, .failed: .red
        case .waitingForBluetooth, .scanning: .secondary
        }
    }

    private var statusIcon: String {
        switch bluetooth.state.phase {
        case .ready: "checkmark.circle.fill"
        case .blocked, .failed: "exclamationmark.circle.fill"
        case .scanning, .connecting, .discoveringServices, .authenticating: "antenna.radiowaves.left.and.right"
        case .waitingForBluetooth, .deviceFound: "circle.fill"
        }
    }

    private var deviceIcon: String {
        bluetooth.hidConnected ? "keyboard.fill" : "keyboard"
    }

    private var keyboardStatus: String {
        if bluetooth.hidConnected { return "已连接" }
        return bluetooth.state.phase == .ready ? "未就绪" : "等待连接"
    }

    private var bothSystemInputsReady: Bool {
        bluetooth.hidConnected && systemMicrophonePipelineReady
    }

    private var systemInputSummary: String {
        if bothSystemInputsReady { return "键盘和系统麦克风均可用" }
        if bluetooth.hidConnected { return "键盘可用，麦克风未就绪" }
        if systemMicrophonePipelineReady { return "麦克风可用，键盘未就绪" }
        return statusText
    }

    private var systemIntegrationDetail: String {
        if bothSystemInputsReady {
            return "Cardputer 键盘和 Cardputer Microphone 均可被 macOS 应用直接使用。"
        }
        if !bluetooth.hidConnected {
            return "BLE HID 键盘尚未就绪。"
        }
        return "Cardputer Microphone 尚未完成 Core Audio 枚举与音频桥接。"
    }

    private var controlStatus: String {
        bluetooth.state.canSendCommand ? "已认证" : "未认证"
    }

    private var micStatus: String {
        bluetooth.micIntent == "live" ? "已开启" : "已静音"
    }

    private var audioStatus: String {
        switch audio.status {
        case .receiving: "正在接收"
        case .listening: "等待设备"
        case .starting: "正在启动"
        case .failed: "不可用"
        case .stopped: "已停止"
        }
    }

    private func faultMessage(_ fault: String) -> String {
        switch fault {
        case "bluetooth_unauthorized": "蓝牙权限被拒绝。请在“系统设置 → 隐私与安全性 → 蓝牙”中允许 Cardputer Bridge。"
        case "bluetooth_powered_off": "这台 Mac 的蓝牙已关闭。"
        case "bluetooth_unsupported": "这台 Mac 不支持所需的 Bluetooth Low Energy。"
        case "vendor_service_missing": "发现了设备，但固件协议不匹配。请确认 Cardputer Bridge 固件版本。"
        default: fault
        }
    }
}

private struct AddShortcutMappingButton: View {
    @EnvironmentObject private var bluetooth: BLEBridgeController
    @EnvironmentObject private var shortcuts: ShortcutConfigController
    @State private var learnToken: UInt32?
    @State private var statusText: String?

    var body: some View {
        Button {
            if let learnToken {
                bluetooth.cancelShortcutLearning(token: learnToken)
                self.learnToken = nil
                statusText = nil
            } else if let token = bluetooth.startShortcutLearning() {
                learnToken = token
                statusText = "请按 Cardputer…"
            }
        } label: {
            Label(
                statusText ?? "添加快捷键",
                systemImage: learnToken == nil ? "plus" : "record.circle"
            )
            .lineLimit(1)
        }
        .disabled(!bluetooth.state.canSendCommand)
        .help(learnToken == nil ? "先从 Cardputer 实机录入触发键" : "取消录入")
        .onChange(of: bluetooth.shortcutLearnEvent) {
            guard let event = bluetooth.shortcutLearnEvent,
                  event.token == learnToken else { return }
            switch event.event {
            case .waiting:
                statusText = "请按 Cardputer…"
            case .captured:
                shortcuts.addMapping(from: event)
                learnToken = nil
                statusText = nil
            case .cancelled:
                learnToken = nil
                statusText = "已取消"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if learnToken == nil { statusText = nil }
                }
            }
        }
        .onDisappear {
            if let learnToken {
                bluetooth.cancelShortcutLearning(token: learnToken)
            }
        }
    }
}

private struct ShortcutMappingRow: View {
    @EnvironmentObject private var shortcuts: ShortcutConfigController
    let mapping: BridgeShortcutMapping

    var body: some View {
        HStack(spacing: 12) {
            CardputerTriggerRecorderField(mapping: mapping) { learned in
                update {
                    $0.triggerIncludesG0 = learned.includesG0 ?? false
                    $0.triggerModifiers = learned.modifiers ?? 0
                    $0.triggerUsage = learned.usage ?? 0
                }
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(BridgeTheme.secondaryText)

            ShortcutRecorderField(
                usage: mapping.outputUsage,
                modifiers: mapping.modifiers,
                mode: .shortcut
            ) { usage, modifiers in
                update {
                    $0.outputUsage = usage
                    $0.modifiers = modifiers
                }
            }
            .frame(maxWidth: .infinity)

            TextField(
                "名称",
                text: Binding(
                    get: { mapping.label },
                    set: { value in update { $0.label = value } }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)

            Toggle(
                "",
                isOn: Binding(
                    get: { mapping.isEnabled },
                    set: { value in update { $0.isEnabled = value } }
                )
            )
            .labelsHidden()
            .frame(width: 46)

            Button(role: .destructive) {
                shortcuts.deleteMapping(id: mapping.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func update(_ change: @escaping (inout BridgeShortcutMapping) -> Void) {
        shortcuts.updateMapping(id: mapping.id, change)
    }
}

private struct CardputerTriggerRecorderField: View {
    @EnvironmentObject private var bluetooth: BLEBridgeController
    let mapping: BridgeShortcutMapping
    let onRecord: (ShortcutLearnEvent) -> Void
    @State private var learnToken: UInt32?
    @State private var statusText: String?

    var body: some View {
        Button {
            if let learnToken {
                bluetooth.cancelShortcutLearning(token: learnToken)
                self.learnToken = nil
                statusText = nil
            } else if let token = bluetooth.startShortcutLearning() {
                learnToken = token
                statusText = "请按 Cardputer…"
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: learnToken == nil ? "keyboard" : "record.circle")
                    .foregroundStyle(
                        learnToken == nil ? BridgeTheme.secondaryText : BridgeTheme.accent
                    )
                Text(statusText ?? displayValue)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(BridgeTheme.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(learnToken == nil ? BridgeTheme.border : BridgeTheme.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(!bluetooth.state.canSendCommand)
        .help(learnToken == nil ? "从 Cardputer 实机录入" : "取消录入")
        .accessibilityLabel("从 Cardputer 实机录入触发键")
        .accessibilityValue(statusText ?? displayValue)
        .onChange(of: bluetooth.shortcutLearnEvent) {
            guard let event = bluetooth.shortcutLearnEvent,
                  event.token == learnToken else { return }
            switch event.event {
            case .waiting:
                statusText = "请按 Cardputer…"
            case .captured:
                onRecord(event)
                learnToken = nil
                statusText = nil
            case .cancelled:
                learnToken = nil
                statusText = "已取消"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if learnToken == nil { statusText = nil }
                }
            }
        }
        .onDisappear {
            if let learnToken {
                bluetooth.cancelShortcutLearning(token: learnToken)
            }
        }
    }

    private var displayValue: String {
        ShortcutRecorderDomain.triggerDisplayValue(
            includesG0: mapping.triggerIncludesG0,
            modifiers: mapping.triggerModifiers,
            usage: mapping.triggerUsage
        )
    }
}

private enum ShortcutRecorderMode {
    case trigger
    case shortcut
}

private struct ShortcutRecorderField: View {
    let usage: UInt8
    let modifiers: UInt8
    let mode: ShortcutRecorderMode
    let onRecord: (UInt8, UInt8) -> Void
    @State private var isRecording = false
    @State private var rejectionMessage: String?
    @State private var isShowingManualEditor = false
    @State private var draftUsage: UInt8 = 0x04
    @State private var draftModifiers: UInt8 = 0

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .foregroundStyle(isRecording ? BridgeTheme.accent : BridgeTheme.secondaryText)
                    Text(isRecording ? recordingPrompt : displayValue)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(BridgeTheme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isRecording ? BridgeTheme.accent : BridgeTheme.border, lineWidth: 1)
                )

                KeyEventCaptureView(
                    mode: mode,
                    isRecording: $isRecording,
                    allowedUsages: mode == .trigger
                        ? ShortcutRecorderDomain.cardputerTriggerUsages
                        : nil,
                    onRecord: { usage, modifiers in
                        rejectionMessage = nil
                        onRecord(usage, modifiers)
                    },
                    onRejected: {
                        rejectionMessage = mode == .trigger
                            ? "此键不可用"
                            : "暂不支持"
                    },
                    onPermissionRequired: {
                        rejectionMessage = "请允许辅助功能"
                    }
                )
            }
            .help(mode == .trigger ? "点击后录入 Cardputer 按键" : "点击后直接录入 Mac 组合键")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mode == .trigger ? "录入 Cardputer 按键" : "录入 Mac 快捷键")
            .accessibilityValue(isRecording ? "等待按键" : displayValue)

            Button {
                draftUsage = usage
                draftModifiers = mode == .trigger ? 0 : modifiers
                isShowingManualEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BridgeTheme.secondaryText)
                    .frame(width: 28, height: 30)
                    .background(BridgeTheme.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(BridgeTheme.border))
            }
            .buttonStyle(.plain)
            .help("手动设置，不触发 macOS 全局快捷键")
            .accessibilityLabel("手动设置快捷键")
            .popover(isPresented: $isShowingManualEditor, arrowEdge: .bottom) {
                ShortcutManualEditor(
                    mode: mode,
                    usage: $draftUsage,
                    modifiers: $draftModifiers,
                    onCancel: { isShowingManualEditor = false },
                    onSave: {
                        rejectionMessage = nil
                        onRecord(
                            draftUsage,
                            mode == .trigger ? 0 : draftModifiers
                        )
                        isShowingManualEditor = false
                    }
                )
            }
        }
    }

    private var displayValue: String {
        guard mode == .shortcut else {
            return "G0 + \(ShortcutRecorderDomain.displayName(for: usage))"
        }
        return ShortcutRecorderDomain.displayValue(
            usage: usage,
            modifiers: modifiers
        )
    }

    private var recordingPrompt: String {
        rejectionMessage ?? (mode == .trigger ? "按键…" : "按组合键…")
    }
}

private struct ShortcutManualEditor: View {
    let mode: ShortcutRecorderMode
    @Binding var usage: UInt8
    @Binding var modifiers: UInt8
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .trigger ? "选择 Cardputer 按键" : "手动设置组合键")
                    .font(.headline)
                Text(mode == .trigger
                    ? "只显示 Cardputer 物理键与 Fn 层可产生的按键。"
                    : "适合被 macOS 占用的全局快捷键；设置时不会真的执行。")
                    .font(.caption)
                    .foregroundStyle(BridgeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mode == .shortcut {
                VStack(alignment: .leading, spacing: 8) {
                    Text("修饰键")
                        .font(.caption)
                        .foregroundStyle(BridgeTheme.secondaryText)
                    HStack(spacing: 8) {
                        modifierButton("L⌃", bit: 0x01, label: "左 Control")
                        modifierButton("L⇧", bit: 0x02, label: "左 Shift")
                        modifierButton("L⌥", bit: 0x04, label: "左 Option")
                        modifierButton("L⌘", bit: 0x08, label: "左 Command")
                    }
                    HStack(spacing: 8) {
                        modifierButton("R⌃", bit: 0x10, label: "右 Control")
                        modifierButton("R⇧", bit: 0x20, label: "右 Shift")
                        modifierButton("R⌥", bit: 0x40, label: "右 Option")
                        modifierButton("R⌘", bit: 0x80, label: "右 Command")
                    }
                }
            }

            Picker("主键", selection: $usage) {
                ForEach(availableKeys) { key in
                    Text(key.name).tag(key.usage)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text(previewValue)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BridgeTheme.accent)
                Spacer()
                Button("取消", action: onCancel)
                Button("应用", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(mode == .shortcut && usage == 0 && modifiers == 0)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private var availableKeys: [HIDKeyDescriptor] {
        if mode == .trigger {
            return ShortcutRecorderDomain.cardputerTriggers
        }
        return [.init(usage: 0, name: "无主键")] + ShortcutRecorderDomain.allKeys
    }

    private var previewValue: String {
        if mode == .trigger {
            return "G0 + \(ShortcutRecorderDomain.displayName(for: usage))"
        }
        return ShortcutRecorderDomain.displayValue(
            usage: usage,
            modifiers: modifiers
        )
    }

    private func modifierButton(
        _ symbol: String,
        bit: UInt8,
        label: String
    ) -> some View {
        let isSelected = modifiers & bit != 0
        return Button {
            modifiers ^= bit
        } label: {
            Text(symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 42, height: 34)
                .foregroundStyle(isSelected ? Color.white : BridgeTheme.primaryText)
                .background(
                    isSelected ? BridgeTheme.accent : BridgeTheme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BridgeTheme.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct KeyEventCaptureView: NSViewRepresentable {
    let mode: ShortcutRecorderMode
    @Binding var isRecording: Bool
    let allowedUsages: Set<UInt8>?
    let onRecord: (UInt8, UInt8) -> Void
    let onRejected: () -> Void
    let onPermissionRequired: () -> Void

    func makeNSView(context: Context) -> ShortcutKeyCaptureNSView {
        let view = ShortcutKeyCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShortcutKeyCaptureNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShortcutKeyCaptureNSView) {
        view.allowedUsages = allowedUsages
        view.captureGlobally = mode == .shortcut
        view.onFocusChanged = { focused in
            DispatchQueue.main.async { isRecording = focused }
        }
        view.onKey = { usage, modifiers in
            onRecord(usage, mode == .trigger ? 0 : modifiers)
        }
        view.onRejected = onRejected
        view.onPermissionRequired = onPermissionRequired
    }
}

private final class ShortcutKeyCaptureNSView: NSView {
    var allowedUsages: Set<UInt8>?
    var captureGlobally = false
    var onFocusChanged: ((Bool) -> Void)?
    var onKey: ((UInt8, UInt8) -> Void)?
    var onRejected: (() -> Void)?
    var onPermissionRequired: (() -> Void)?
    private lazy var eventTap = GlobalShortcutEventTap(
        onCapture: { [weak self] result in
            self?.onKey?(result.usage, result.modifiers)
            self?.window?.makeFirstResponder(nil)
        },
        onCancel: { [weak self] in
            self?.window?.makeFirstResponder(nil)
        },
        onRejected: { [weak self] in
            NSSound.beep()
            self?.onRejected?()
        }
    )

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        if captureGlobally, !eventTap.start() {
            onPermissionRequired?()
            onFocusChanged?(false)
            return false
        }
        onFocusChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        eventTap.stop()
        onFocusChanged?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !captureGlobally else { return }
        if ShortcutRecorderDomain.shouldCancelRecording(forMacKeyCode: event.keyCode) {
            window?.makeFirstResponder(nil)
            return
        }
        guard let usage = ShortcutRecorderDomain.hidUsage(forMacKeyCode: event.keyCode),
              allowedUsages?.contains(usage) != false else {
            NSSound.beep()
            onRejected?()
            return
        }
        let flags = event.modifierFlags
        onKey?(usage, ShortcutRecorderDomain.modifiers(
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            command: flags.contains(.command)
        ))
        window?.makeFirstResponder(nil)
    }

}

@MainActor
private final class GlobalShortcutEventTap {
    private let onCapture: (ShortcutCaptureResult) -> Void
    private let onCancel: () -> Void
    private let onRejected: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = ShortcutCaptureState()

    init(
        onCapture: @escaping (ShortcutCaptureResult) -> Void,
        onCancel: @escaping () -> Void,
        onRejected: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onRejected = onRejected
    }

    func start() -> Bool {
        stop()
        // The exported ApplicationServices constant is imported as mutable
        // global state and is rejected by Swift 6 strict concurrency. Its
        // documented CFString value is stable and safe to construct locally.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return false }

        state = ShortcutCaptureState()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else {
                    return Unmanaged.passUnretained(event)
                }
                let recorder = Unmanaged<GlobalShortcutEventTap>
                    .fromOpaque(context).takeUnretainedValue()
                let keyCode = UInt16(event.getIntegerValueField(
                    .keyboardEventKeycode
                ))
                // This tap source is installed on the main run loop below.
                let shouldSuppress = MainActor.assumeIsolated {
                    recorder.handle(type: type, keyCode: keyCode)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        state = ShortcutCaptureState()
    }

    private func handle(
        type: CGEventType,
        keyCode: UInt16
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        switch type {
        case .flagsChanged:
            if let result = state.modifierTransition(macKeyCode: keyCode) {
                finish(with: result)
            }
        case .keyDown:
            if ShortcutRecorderDomain.shouldCancelRecording(
                forMacKeyCode: keyCode
            ) {
                onCancel()
                stop()
            } else if let usage = ShortcutRecorderDomain.hidUsage(
                forMacKeyCode: keyCode
            ) {
                state.primaryDown(macKeyCode: keyCode, usage: usage)
            } else {
                onRejected()
            }
        case .keyUp:
            if let result = state.primaryUp(macKeyCode: keyCode) {
                finish(with: result)
            }
        default:
            break
        }
        // Suppress the chord while recording so an existing global binding is
        // neither executed nor able to steal the event from this recorder.
        return true
    }

    private func finish(with result: ShortcutCaptureResult) {
        onCapture(result)
        stop()
    }
}

private struct AudioLevelBars: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let normalized = isActive ? perceptualLevel : 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<28, id: \.self) { index in
                    let threshold = Double(index + 1) / 28
                    Capsule()
                        .fill(threshold <= normalized ? BridgeTheme.success : BridgeTheme.surfaceRaised)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.12), value: perceptualLevel)
    }

    private var perceptualLevel: Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(max(level, 0.000_001))
        return min(1, max(0.04, (decibels + 60) / 48))
    }
}

private enum DailySection: String, CaseIterable, Identifiable {
    case overview
    case shortcuts
    case microphone
    case device
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .shortcuts: "快捷键"
        case .microphone: "麦克风"
        case .device: "设备与连接"
        case .settings: "设置"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .overview: "house"
        case .shortcuts: "command"
        case .microphone: "mic"
        case .device: "externaldrive.connected.to.line.below"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

private enum BridgeTheme {
    static let background = Color(red: 7 / 255, green: 8 / 255, blue: 10 / 255)
    static let surface = Color(red: 16 / 255, green: 17 / 255, blue: 17 / 255)
    static let surfaceRaised = Color(red: 28 / 255, green: 29 / 255, blue: 31 / 255)
    static let border = Color.white.opacity(0.09)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.55)
    static let accent = Color(red: 1, green: 99 / 255, blue: 99 / 255)
    static let success = Color(red: 89 / 255, green: 213 / 255, blue: 156 / 255)
    static let warning = Color(red: 1, green: 190 / 255, blue: 91 / 255)
}

private struct BridgePanelModifier: ViewModifier {
    let border: Color

    func body(content: Content) -> some View {
        content
            .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(border, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.black.opacity(0.45), lineWidth: 1)
                    .padding(2)
            )
            .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }
}

private struct BridgeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            configuration.label
                .font(.headline)
                .foregroundStyle(BridgeTheme.primaryText)
            configuration.content
        }
        .padding(18)
        .bridgePanel()
    }
}

private extension View {
    func bridgePanel(border: Color = BridgeTheme.border) -> some View {
        modifier(BridgePanelModifier(border: border))
    }
}

private struct BridgePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .frame(minWidth: 220, minHeight: 44)
            .background(
                configuration.isPressed
                    ? BridgeTheme.accent.opacity(0.75)
                    : BridgeTheme.accent,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12))
            )
            .shadow(color: BridgeTheme.accent.opacity(0.2), radius: 12)
    }
}

private struct CardputerProductImage: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(
                forResource: "cardputer-adv-raycast-cutout",
                withExtension: "png"
            ), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: 52))
                    .foregroundStyle(BridgeTheme.secondaryText)
            }
        }
        // 84 mm converted at the 72 point/inch UI baseline. Shrink only.
        .frame(maxWidth: 238, maxHeight: 143)
        .accessibilityLabel("Cardputer-ADV")
    }
}
