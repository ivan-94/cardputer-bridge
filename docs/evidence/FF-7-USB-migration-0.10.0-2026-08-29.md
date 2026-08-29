# FF-7 USB 迁移实机证据（0.10.0）

## 结论

2026-08-29，Cardputer-Adv 已从旧的单应用分区布局迁移到 `0.10.0` 的 `factory + ota_0 + ota_1` 布局。迁移不执行整片擦除，未写入 NVS `0x9000–0xefff`；旧的 Wi-Fi、bond 和 schema v3/version 49 配置均被保留。

本次证据解除了“分区迁移会否真实可启动、会否覆盖用户配置”这一部分 FF-7 风险。它不等于 OTA 与断电 rollback 已通过。

## 环境与目标

- 设备：Cardputer-Adv / ESP32-S3 rev 0.2 / 8 MiB Flash
- USB Serial/JTAG：`/dev/cu.usbmodem2101`
- 设备 MAC：`9c:cc:01:e0:a6:6c`
- 源码基线：`e989129299ff03dcc915736e87790b235b3e3265`
- 固件版本：`0.10.0`
- ESP-IDF：`5.4.2`
- 写入器：`espflash 4.5.0` macOS arm64，SHA-256 `6614ff70e523a6bce5f4ccc6459b77275f5e7e900429004bb7eec463c95db28a`

## 写入范围

按 macOS App 中固定的 fail-fast 顺序写入：应用先行，bootloader 最后，中途不执行 `erase_flash`。

| 顺序 | 偏移 | 产物 | SHA-256 | 结果 |
| ---: | ---: | --- | --- | --- |
| 1 | `0x10000` | `cardputer_bridge_firmware.bin` | `64fcd50a6d0a0339258d87bf7ef04908ca4b7e4c6252846d92d3079c1a1ca5a8` | PASS |
| 2 | `0x610000` | `ota_data_initial.bin` | `7d2c7ac4888bfd75cd5f56e8d61f69595121183afc81556c876732fd3782c62f` | PASS |
| 3 | `0x8000` | `partition-table.bin` | `cfc32398e46bf6edb01102436e2530379574bd03cb257d29b742b8c47fadde7a` | PASS |
| 4 | `0x0` | `bootloader.bin` | `c3ea49948072b7a6d2611b2893b082fcb2b8ca1612c4831c9fce55b0f352fcef` | PASS |

写入后再用 `esptool verify_flash` 对四个区域逐字节比对，四项均返回 `verify OK (digest matched)`。

## 运行时验证

1. Boot HIL 返回 `ready`：键盘就绪、BLE HID advertising、vendor GATT 为 encrypted MITM、Wi-Fi audio 等待配置。
2. 固件在键盘与音频服务启动后返回 `firmware_health_confirmed`，新镜像被标记为健康。
3. 保留状态：SSID `LEE@Turbo`、IP `192.168.2.111`、`config_schema=3`、`config_version=49`、电量 100%。
4. Serial-control HIL 通过：鉴权、heartbeat、`mic live`、租约过期后回到 `muted/closed`。
5. macOS App 重启后 runtime probe 为 `phase=ready`、`radio=poweredOn`、`hid_connected=true`，设备状态为 Wi-Fi connected / audio ready。
6. BLE heartbeat HIL 通过：`physical_ble_authenticated=true`、`control_authenticated=true`、`ble_heartbeat_total` 增长，`control_command_drops=0`。
7. 稳态观察中 `udp_failures=0`、`capture_overruns=0`；默认保持 `muted/closed`。

## 本次暴露并固化的回归

- `espflash list-ports --name-only` 在 macOS 会同时返回同一物理设备的 `/dev/cu.*` 和 `/dev/tty.*`。App 原本会误报“连接了多台设备”；现统一为 `/dev/cu.*` 后去重，并用两个 Swift 回归测试覆盖单设备别名与真实多设备。
- 旧 boot verifier 在 USB Serial/JTAG 控制线尚未稳定时立即脉冲 RTS，可把 ESP32-S3 留在 ROM downloader。现在先将 RTS/DTR 稳定到 idle，再执行应用重启；实机 boot HIL 已通过。
- Runtime HIL 原本在 USB 打开后固定等待 400ms，会在命令循环尚未启动时丢失指令。现改为等待结构化 `ready`/首个 telemetry 事件后再发送命令。
- 生产签名校验现显式指定 production build directory，不再意外配置另一个默认 `firmware/build` 目录。

## 未解除的 Gate

- 未从 App UI 完整点击一遍下载→写入→重连；本次使用与 App 相同的固定 `espflash` 版本、hash、分区和写入顺序执行实机迁移。
- 未验证真实 HTTPS OTA；本证据生成时仓库为 private。仓库随后已切换为 public，但首个签名 Release 与真实下载/安装尚未执行。
- 未执行 OTA 下载/写入途中的断电矩阵，也未实机观察 rollback 回到上一健康槽。
- 未执行 15 分钟及以上 soak；启动时曾出现一次 HID report failure 计数，后续观察未增长，仍应在 soak 中确认为连接前的瞬态发送而非稳态故障。

## Source Manifest

### Sources

- `../../../../specs/Cardputer-Bridge-实现-Spec.md` — FF-7、fail-fast、分区、NVS 保留与 rollback 合同。
- `../../README.md` — 安装入口、当前生产化边界与旧 HIL 基线。
- `../../macos/Sources/CardputerBridgeApp/FirmwareUpdateController.swift` — USB 写入顺序与端口发现。
- `../../scripts/build-production-firmware.sh` — RSA-3072 签名生产构建。
- Cardputer-Adv USB Serial/JTAG 的现场 boot/runtime/flash verify 输出，2026-08-29。

### Produced artifacts

- 本证据页。
- macOS USB 端口 canonicalization 及回归测试。
- USB app-reset 与 runtime-ready HIL 脚手回归修复。

### Key decisions

- 普通升级不擦除整片 Flash，NVS 永远不在迁移写入集中。
- 四区写入使用应用→OTA data→分区表→bootloader 顺序，且每个产物先通过 SHA-256 校验。
- 本次只宣称 USB 迁移与升级后主链路通过，不将 OTA/rollback 推断为 PASS。

### Verification evidence

- `./scripts/verify-contracts.sh` — 73 项 contract（包含故意失败 fixture）通过。
- `./scripts/verify-host.sh` — 11/11 CTest 与外部 verifier 通过。
- `./scripts/verify-macos.sh` — 71/71 XCTest、UI policy、arm64 App 构建与 ad-hoc 签名通过。
- `esptool verify_flash` — 四个区域全部 digest matched。
- `./scripts/verify-hil.sh` — boot `ready` PASS。
- `./scripts/verify-runtime-hil.sh --mode serial-control` — PASS。
- `./scripts/verify-runtime-hil.sh --mode ble-heartbeat --observation-seconds 6` — PASS。
- firmware telemetry — `firmware_health_confirmed`、`control_command_drops=0`、`udp_failures=0`、`capture_overruns=0`。

### Open questions / risks

- 正式更新采用公开 GitHub Release；本地开发采用 Mac 选择本机 `.bin` 后通过局域网交给同一 OTA 安装链路。后者尚未实现。
- 仓库已经公开，但首个签名 Release 资产尚未发布。
- OTA 断电 rollback、长时 soak 和真实 App UI installer 流程仍需实机验收。
