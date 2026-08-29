@preconcurrency import CoreWLAN
import Foundation

struct NearbyWiFiNetwork: Identifiable, Sendable {
    let ssid: String
    let rssi: Int
    let channel: Int

    var id: String { ssid }

    var signalSymbol: String {
        if rssi >= -55 { return "wifi" }
        if rssi >= -70 { return "wifi" }
        return "wifi.exclamationmark"
    }
}

@MainActor
final class NearbyWiFiController: ObservableObject {
    @Published private(set) var networks: [NearbyWiFiNetwork] = []
    @Published private(set) var isScanning = false
    @Published private(set) var fault: String?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        fault = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.scanNearby2GHzNetworks()
            }.value
            networks = result.networks
            fault = result.fault
            isScanning = false
        }
    }

    nonisolated private static func scanNearby2GHzNetworks() -> (
        networks: [NearbyWiFiNetwork],
        fault: String?
    ) {
        guard let interface = CWWiFiClient.shared().interface() else {
            return ([], "这台 Mac 没有可用的 Wi-Fi 接口。")
        }
        do {
            let discovered = try interface.scanForNetworks(withSSID: nil)
            var strongestBySSID: [String: NearbyWiFiNetwork] = [:]
            for network in discovered {
                guard let ssid = network.ssid?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !ssid.isEmpty,
                      let channel = network.wlanChannel,
                      channel.channelNumber <= 14 else {
                    continue
                }
                let candidate = NearbyWiFiNetwork(
                    ssid: ssid,
                    rssi: network.rssiValue,
                    channel: channel.channelNumber
                )
                if candidate.rssi > (strongestBySSID[ssid]?.rssi ?? Int.min) {
                    strongestBySSID[ssid] = candidate
                }
            }
            return (
                strongestBySSID.values.sorted {
                    $0.rssi == $1.rssi ? $0.ssid < $1.ssid : $0.rssi > $1.rssi
                },
                nil
            )
        } catch {
            return ([], "无法扫描 Wi-Fi：\(error.localizedDescription)")
        }
    }
}
