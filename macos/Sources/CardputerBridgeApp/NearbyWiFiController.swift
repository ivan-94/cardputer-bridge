@preconcurrency import CoreWLAN
@preconcurrency import CoreLocation
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
final class NearbyWiFiController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var networks: [NearbyWiFiNetwork] = []
    @Published private(set) var isScanning = false
    @Published private(set) var fault: String?

    private let locationManager: CLLocationManager
    private var scanAfterAuthorization = false

    override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
    }

    func scan() {
        guard !isScanning else { return }
        fault = nil
        isScanning = true
        Task {
            let servicesEnabled = await Task.detached(priority: .userInitiated) {
                CLLocationManager.locationServicesEnabled()
            }.value
            guard servicesEnabled else {
                isScanning = false
                fault = "请先在系统设置中开启定位服务，才能扫描附近的 Wi-Fi。"
                return
            }
            continueScanAfterLocationServicesCheck()
        }
    }

    private func continueScanAfterLocationServicesCheck() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            scanAfterAuthorization = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginScan()
        case .denied, .restricted:
            isScanning = false
            fault = "请在系统设置 > 隐私与安全性 > 定位服务中允许 Cardputer Bridge。"
        @unknown default:
            isScanning = false
            fault = "无法确认 Wi-Fi 扫描权限，请稍后重试。"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        guard scanAfterAuthorization else { return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            scanAfterAuthorization = false
            beginScan()
        case .denied, .restricted:
            scanAfterAuthorization = false
            isScanning = false
            fault = "请在系统设置 > 隐私与安全性 > 定位服务中允许 Cardputer Bridge。"
        case .notDetermined:
            break
        @unknown default:
            scanAfterAuthorization = false
            isScanning = false
            fault = "无法确认 Wi-Fi 扫描权限，请稍后重试。"
        }
    }

    private func beginScan() {
        isScanning = true
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
                      channel.channelBand == .band2GHz else {
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
            return ([], "无法扫描附近的 Wi-Fi，请检查系统权限后重试。")
        }
    }
}
