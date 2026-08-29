# FF-2：BLE 复合设备 Gate

## 当前 verdict

- Input Router preflight：`PASS`（E0–E2）。
- 真机 boot、BLE HID + encrypted/MITM vendor GATT、Mac App heartbeat、`Q`、`G0+Q → ⌃⌘Q` 与重启自动重连：`PASS`（E4 机器子项）。
- macOS HID consumer 权限与 active event tap preflight：`PASS`。
- FF-2 产品 Gate：`HUMAN_GATE`；`scripts/verify-ff-2.sh` 与正式 evidence runner 均以 exit 3 停在实体 Cardputer 键盘来源验收，不把 serial Action 冒充物理输入。
- FR-001 / FR-002 / FR-003：`NOT_RUN`。

旧文档中“无真机、BLE adapter 未实现”的结论已过期。当前 Cardputer-Adv 已直接刷入并运行复合 BLE 固件：标准 HID report 与加密 vendor GATT 共用同一物理连接，Swift App 以 `.withResponse` 单在途写入 heartbeat。USB Serial/JTAG 可读取 `physical_ble_authenticated`、`hid_connected`、report 计数和 `input_all_keys_up`，也可将 `Q` / `G0+Q` 注入与实体键盘相同的 `InputRouter` 路径。

## 已实现的可证伪边界

`firmware/components/input_router/` 不依赖 M5Unified 或 BLE callback，接收已规范化的键事件和虚拟时间，产生 HID report、麦克风意图或屏幕反馈 effect。已覆盖：

1. 普通 `Q` 产生平衡的 down/up；
2. `G0 + Q` 产生 modifier `0x09` + usage `0x14`，即 US 布局下的 `⌃⌘Q`；
3. G0 + 未映射键只产生 `NOT MAPPED`，不泄漏普通 HID 输入；
4. G0 350ms 内独立释放才切换麦克风意图，长按或 chord 后释放均不切换；
5. BLE 断开 effect 先释放 usage 和 modifier，再把 `control_link_lost` 交给 fail-closed 领域路径；
6. 最多 32 条 mapping 采用先完整校验、后替换，非法更新不破坏 last-known-good。

独立 `input_event_stream` verifier 不信任实现端的“我已释放”布尔值；它自己重放 HID report，因而会拒绝已按下 `⌃⌘Q` 却遗漏 key-up 的 RED fixture。

## 单命令入口

```bash
make verify-ff-2-preflight
make evidence-ff-2-preflight
make verify-ff-2
make evidence-ff-2
```

`verify-ff-2-preflight` 不扫描或配对蓝牙，不写 NVS，不烧录设备。`verify-ff-2` 只在 preflight 通过后进入真机步骤；无串口、系统事件权限不足或设备不响应都必须明确返回 `BLOCKED` / `FAIL`，不得 SKIP。

`verify-ff-2` 现在是真实机器 Gate，不再用“adapter 未实现”作占位：

1. 先对 macOS active event tap 做 fail-fast preflight，权限不足时在重启设备前 exit 2；
2. 重建并重启当前 Swift App；
3. 重启 Cardputer，由串口验证 boot contract，再要求 App 自动恢复 encrypted GATT heartbeat；
4. 分别验证 `Q` 和 `G0+Q → ⌃⌘Q`：macOS consumer 核对 keycode/modifier/down/up，固件计数器核对恰好两个 report、零失败且最终 all-keys-up；
5. 再重启一次设备验证 HID/GATT 同时恢复；App 对无回调 heartbeat 设 2 秒 watchdog，重建 CoreBluetooth session，并用已保存的 peripheral UUID 直接取回已经被系统 HID 接走、因而不再广播的设备；
6. 机器子项都通过后 exit 3，明确等待实体 Cardputer 键盘来源验收。

macOS 锁屏时 Secure Input 由 `loginwindow` 持有，系统仍接收 BLE 键盘，但 CGEvent oracle 无法观察事件。runner 现在会在任何 HID Action 前 fail fast 返回 `BLOCKED macos_session_locked`，不会把锁屏误判为 HID 故障。

## 退出 Gate 还缺什么

1. 用 Cardputer 实体键盘输入 `Q` 与 `G0+Q`，而不是 serial harness 注入，补齐 `source=keyboard` 证据。
2. 用实体键盘验证未映射 chord 不透传，并在按键按下期间强制断链，独立确认 macOS 无粘键。
3. 扩大按键样本并完成长时 BLE HID/GATT soak；当前连续 3 轮设备重启/自动重连均通过，但不能替代长时稳定性。

## Source Manifest

### Sources

- `../../../../specs/Cardputer-Bridge-实现-Spec.md` — FF-2、FR-001/002/003、G0 状态机、BLE UUID 和 E4 证据要求。
- `../../../../02a-Cardputer-构建-harness.md` — 同路径 Action、RED fixture、外部 verifier 与 host/真机边界。
- 本机 ESP-IDF 6.0.2 `examples/bluetooth/esp_hid_device` — BLE HOGP adapter 的上游 API 样例。

### Produced artifacts

- `../../firmware/components/input_router/`
- `../../harness/contracts/ff-2.json`
- `../../harness/fake-device/input_router_host.cpp`
- `../../harness/verifier/input_event_stream.py`
- `../../harness/fixtures/input-router-scenario.ndjson`
- `../../harness/fixtures/invalid-hid-events.ndjson`
- `../../scripts/verify-ff-2-preflight.sh` 与 `../../scripts/verify-ff-2.sh`
- `../../scripts/verify-hid-hil.sh` 与 `../../scripts/verify_hid_hil.py`
- `../../harness/macos/macos_hid_event_consumer.c`
- `../../harness/verifier/macos_hid_event_stream.py`

### Evidence boundary

- `FF2_PREFLIGHT_PASS` 的最高证据等级为 E2。
- 当前直刷镜像大小 `0xe4af0`；固件在每次认证边界先发送 all-keys-up 同步报告，真实按键仍由独立 macOS oracle 判定。
- 阶段性已接受证据：`artifacts/verification/20260828T045717.467404Z-ff2`，evidence level `E4`，机器命令完成 2/2，suite verdict `HUMAN_GATE`，最终 exit 3；该本地目录不默认提交。
- 本地 runner 在 `artifacts/verification/` 保留 source manifest、命令、coverage 和 verdict，该目录不默认提交。
