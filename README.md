# Cardputer Bridge

Cardputer Bridge 的正式实现工程。当前已形成一个面向本机使用的完整竖切：Cardputer-ADV 作为 BLE 辅助快捷键盘，通过 2.4GHz Wi-Fi 向 macOS 传输麦克风音频，SwiftUI App 负责首次设置、快捷键映射、系统麦克风、连接与运行设置。工程保留 Harness-first 的可验证边界；录音期间实体 RGB LED 红色常亮，静音后熄灭。研究级长时 soak 与多应用听感不属于本次本机可用版收尾门槛。

源码仓库：[ivan-94/cardputer-bridge](https://github.com/ivan-94/cardputer-bridge)。在 AI Wiki 中，它仍以 Git submodule 保持在原路径 `outputs/books/玩转-Cardputer/projects/cardputer-bridge`。

## 安装与更新

macOS App 是安装入口，用户不需要先配置 ESP-IDF。首次设置的欢迎页和日常设置页都提供“Cardputer 固件”入口：

1. App 从 GitHub Release 下载签名发布清单，先校验内置的 Ed25519 发布公钥。
2. 旧的单分区固件（`0.9.x`）需要一次 USB 迁移。App 会下载、校验 SHA-256，然后用固定版本且已校验的 `espflash` 写入 factory、OTA data、partition table 和 bootloader。流程不执行整片擦除，因此 NVS 配置保留。
3. 迁移到 `layout 2` 后，后续版本通过 Wi-Fi HTTPS OTA 安装，BLE 只传递经验证的版本和下载地址指令。
4. 固件拒绝降级、错误产品镜像和不完整下载。新镜像在键盘与音频服务成功启动并稳定运行 10 秒后才标记为健康；否则下次启动回滚。

当前生产固件版本为 `0.10.0`，分区包含 `factory` 和两个 2 MiB OTA 槽。本地 RSA-3072 生产签名构建已通过；这个策略防止远程 OTA 替换为未签名固件，但尚未熔断 Secure Boot eFuse，因此拥有物理接触的人仍可用 ROM download mode 重刷设备。

> 发布门槛：仓库目前保持 private，匿名用户无法下载 GitHub Release，所以 OTA 只在仓库公开或迁移到公开资产服务后才算真正可用。macOS App 目前没有 Developer ID 证书，可在本机构建运行，但不应伪装成已可无提示分发的正式 App。

最快的本机入口：

```bash
./scripts/build-macos.sh
./scripts/restart-macos-app.sh
```

## 当前可执行入口

```bash
make verify-env
make verify-contracts
make verify-host
make evidence-host
make verify-ff-0
make evidence-ff-0
make verify-ff-1-preflight
make evidence-ff-1-preflight
make verify-ff-1
make verify-ff-2-preflight
make evidence-ff-2-preflight
make verify-ff-2
make verify-hid-hil-preflight
make verify-hid-hil
make verify-hil
make verify-phase-2
make verify-phase-3
make verify-restart-mute-hil
make verify-device-mic-authority-hil
make verify-audio-latency-hil
make verify-system-microphone-ui-hil
```

`make verify` 是聚合入口，已接入 Cardputer USB boot HIL。`make verify-ff-2` 是更完整的复合 BLE Gate：它先 fail-fast 检查 macOS 会话与事件 consumer，再验证设备重启、encrypted GATT heartbeat、`Q`、`G0+Q → ⌃⌘Q`、all-keys-up 和二次重连。机器子项通过后，底层 `scripts/verify-ff-2.sh` 与 evidence runner 会以 exit 3 进入实体键盘 human gate，不会用 harness 注入冒充实体输入；GNU Make 会把非零 recipe 状态统一显示为目标失败，因此需要 verdict 时以脚本或 evidence runner 输出为准。

`make verify-ff-1-preflight` 验证 FF-1 Stage B：Gate contract/RED fixture、Plug-in 属性、Driver-owned anonymous buffer、Unix `SCM_RIGHTS` fd broker、双向 `getpeereid` UID 合同、consumer-first、stop/crash/restart、恶意 socket、畸形 fd 消息、损坏 ring、确定性 PCM oracle和临时 HAL root 的可恢复安装/移出。它不会写入 `/Library/Audio/Plug-Ins/HAL` 或重启服务；macOS 27+ 上 Core Audio client 枚举与 PCM consumer 会标记 `NOT_RUN`，真实 FF-1 则在枚举前 fail fast。

`make verify-ff-2-preflight` 使用同一个纯 C++ `InputRouter` 验证普通按键、G0 短按、G0 快捷层、未映射吞键、长按和断链 all-keys-up；独立 Python verifier 会拒绝故意缺失 key-up 的 RED fixture。这是 E0–E2 的输入内核证据，不是 BLE HOGP/GATT 或 macOS 系统输入已通过。

## 当前证据边界

- FF-0 已通过：Cardputer-ADV/M5Unified 固件、SwiftUI `.app`、最小 Audio Server Plug-in `.driver` 均可在本机重复构建。
- 已实现 E1：C++17 与 Swift `BridgeDomain`/reducer 在 host 上验证麦克风授权与控制链失联 fail-closed。
- 已实现 E2：真实领域内核产生结构化事件，独立 Python verifier 判定；故意错误事件流和错误 Audio bundle fixture 均会稳定失败。
- 已实现 E3 前置候选：Plug-in 发布 48kHz/mono/Float32 输入流和真实 consumer 所需属性；Driver 创建并预映射匿名 buffer，producer 通过 `SCM_RIGHTS` 获取 fd。测试覆盖双方 UID 拒绝、consumer-first、确定性 pulse、stop/crash 静音、producer restart、生命周期锁与启动竞态、恶意/活跃路径保留、短协议头/多 fd/截断 ancillary 消息不泄漏、损坏 ring 静音和独立 consumer/installer/oracle。它们在同 UID harness 中执行，不等于真实跨 UID PASS。
- 真实 E3 已在 macOS 27.0 build `26A5421a` 重跑：`Cardputer Microphone` 已发布为 48kHz/mono/Float32 系统输入，独立系统 consumer 捕获合成 pulse 的 `active_peak=0.5`，producer 的共享读指针推进 `28612` 帧，停止与 consumer 重启后的尾部均为数字静音。一次 stale broker endpoint 清理 + `coreaudiod` reload 已恢复枚举、App bridge 和系统 PCM；多次 reload/30 分钟 soak 与三个常用 App 的系统 UI/听感验收仍未完成。
- FF-2 host preflight 已通过：固定容量的 C++ Input Router 和虚拟时间状态机已进入 ESP-IDF 固件构建；`Q` 、`G0+Q → ⌃⌘Q`、未映射键、G0 短/长按和断链释放都由结构化事件与外部 oracle 判定。
- FF-2 已进入真机 E4：Cardputer-Adv 直接启动固件已实现 BLE HID、encrypted/MITM vendor GATT、`.withResponse` heartbeat、USB Serial/JTAG Action/diagnostic 和 App 无点击重连。真机已证明 heartbeat 到达、App 退出后 1.2s fail-closed、`Q` 与 `G0+Q → ⌃⌘Q` 的真实 macOS down/up 事件，以及设备重启后 GATT/HID 恢复。
- 重连链路已处理两类真实故障：无回调 heartbeat 由 2 秒 watchdog 重建 CoreBluetooth session；系统 HID 已接回且设备停止广播时，App 用已保存 UUID 从 CoreBluetooth cache 直接取回 peripheral。连续 3 轮设备重启/自动重连均通过。
- Phase 2 的 encrypted GATT 分片、SHA-256 绑定、NVS commit 后激活和重启持久化已有既往真机证据：配置版本 v2→v3、`muted/closed`、`control_command_drops=0`。本次收尾把 canonical format 升为 schema v3，每条映射携带 UUID，设备拒绝重复 ID；设备仍可读取 schema v1/v2，Mac 只写 v3。最终候选刷入后，App 已把设备保留的 schema v2/version 48 原子迁移为 schema v3/version 49，末态 `muted/closed`、`control_command_drops=0`。真机断电注入矩阵和 canonical hash ack 仍属于后续研究 Gate。
- Phase 3 真机音频竖切已通过并接入系统输入：Cardputer 采集 16kHz mono PCM，以 20ms 帧和 AES-256-GCM 通过 Wi-Fi UDP 送到 App；App 使用 60ms 启动水位/40ms 重排的 jitter buffer、`AVAudioConverter` 16kHz→48kHz 高质量重采样、1.25× 增益/软限幅和 v3 SPSC ring 写入 `Cardputer Microphone`。ring 积压超过 100ms 会丢弃过期音频并追到最新 20ms；真机积压 3 秒后启动系统 consumer 的声学延迟上界为 156.1ms。ESP-IDF 6.0.2 会让 Cardputer-ADV/ES8311 只返回常量 `-8`，已按上游复现锁定 ESP-IDF 5.4.2。
- SwiftUI 产品壳已可运行：六步首次设置没有侧栏，返回按钮位于顶部步骤栏；完成后进入概览、快捷键、麦克风、设备与连接、设置、关于六个原生 macOS 入口。界面使用 `DESIGN.md` 的 Raycast token 和透明 Cardputer 图，产品图最大 238pt，已在 920×650 真机窗口截图复核。
- 日常使用能力已补齐：菜单栏常驻、登录时自动启动、2.4GHz Wi-Fi 扫描、Cardputer 任意实体键/组合键学习、Mac 端特殊键/左右修饰键/无主键录入、最近真实触发记录、电量与 Wi-Fi 信号遥测、单实例保护与脱敏诊断报告导出。
- App 重启恢复不再信任设备遗留的 `audio:ready`：只有当前进程收到通过认证的 UDP 包才算 session 就绪，否则自动协商新 session。新 App 进程总是以 muted 为意图基线；真机重启 1538–1988ms 内设备回到 `muted/closed`，独立系统 PCM 的 active/tail peak 均为 0。Cardputer 端发起的 live 意图也能跨过 App heartbeat 保持，不会被旧默认值覆盖。macOS 62/62 tests 通过。
- Cardputer 端已有状态驱动的离屏绘制、真实电平、BLE/Wi-Fi/电量图标、15 秒降亮、30 秒息屏与静音时 Wi-Fi 省电。Cardputer-Adv 的 GPIO38 同时控制 LCD 背光与 RGB LED 供电；录音时固件保持共享供电恒高、红灯常亮并暂停息屏，静音时先熄灯再恢复屏幕功耗策略。15 秒 red→off HIL 与用户肉眼确认均已通过。
- 正式 FF-2 evidence verdict 为 `HUMAN_GATE`：机器链路已通过；实体键盘来源、实体未映射 chord、按键中途强断 all-keys-up、大样本/soak，以及后续 Wi-Fi/I²S/资源指标仍待验证。
- 尚未完成 E5：实体 TFT、Audio MIDI Setup/浏览器/会议 App 的系统 UI 证据和用户最终听感。Phase 3/4 仍缺自适应时钟漂移、1%/5%/突发丢包、路径切换故障注入、多次 reload、15 分钟/2h/30 分钟 soak；已有自动指标不代表最终音质已验收。

## Source Manifest

### Sources

- `../../specs/Cardputer-Bridge-实现-Spec.md` — 产品、架构、Gate、Harness 和 Definition of Done 的事实源。
- `../../02a-Cardputer-构建-harness.md` — 同一 Action 路径、结构化观测、外部 verifier 与证据边界的方法来源。
- `../../prototypes/cardputer-bridge/README.md` — 已确认的双端交互范围；不是生产代码来源。
- `../../DESIGN.md` — SwiftUI Raycast 视觉 token、层级、颜色与组件纪律的事实源。
- M5Unified `0.2.21` 与 ESP-IDF `5.4.2` — 当前 Cardputer-ADV 麦克风可工作的固定构建组合。
- [M5Stack Cardputer-Adv](https://docs.m5stack.com/en/core/Cardputer-Adv) — GPIO38 是 Stamp-S3A RGB LED 的独立电源开关，并与 LCD 背光电源使能共享。
- [Espressif esp-idf#18621](https://github.com/espressif/esp-idf/issues/18621) — Cardputer-ADV/ES8311 在 IDF 5.5.1 返回常量 `-8`、5.4.2 正常的上游复现与临时 workaround。

### Produced artifacts

- `firmware/components/bridge_domain/` — 与硬件框架隔离的 C++17 领域内核。
- `firmware/components/input_router/` — 无动态增长的 HID/G0 状态机，host 与 ESP-IDF 共用。
- `firmware/components/shortcut_config/` — host/固件共用的 canonical config、分片事务和 NVS last-known-good。
- `harness/verifier/` — 独立事件流 verifier。
- `harness/contracts/ff-1.json` 与 `ff-2.json` — 系统麦克风与 BLE 复合设备的可执行验证合同；产品代码不能自行宣告 Gate 通过。
- `docs/evidence/FF-1-macOS-27-runtime-2026-08-28.md` — 真实 HAL A/B 的环境、源码/二进制 hash、观测数值、恢复结果和证据局限。
- `tests/unit/` 与 `tests/integration/` — host 行为与真实领域事件验证。
- `artifacts/verification/` — 本地运行证据，不默认提交。
- `macos/Resources/cardputer-adv-raycast-cutout.png` — 从已确认原型复用的透明设备图，用于首次设置欢迎页。

### Key decisions

- 先实现 fail-closed 领域 seam，再接硬件、BLE、音频和 UI。
- Harness 注入与真实适配器必须进入同一个 `BridgeDomain::dispatch()`。
- 默认 `make verify` 不把尚未实现的 HIL 当作通过。
- ESP GCC 15.2.0 的 specs 路径不能可靠处理当前中文工程路径；源码仍留在 canonical 目录，固件生成物固定到 `$HOME/.local/share/cardputer-bridge/build/firmware`，不依赖临时目录。

### Verification evidence

- `make verify-contracts` 必须证明错误 fixture 返回非零。
- `make verify-host` 构建 C++17 内核并运行 CTest/Python 外部 verifier。
- `make evidence-host` 生成绑定 Git 状态、工具链、命令和退出码的证据包。
- `make verify-ff-0` 重建并检查固件镜像、SwiftUI App、HAL Plug-in bundle 与 factory probe。
- `make evidence-ff-0` 将 FF-0 的原始输出、退出码、版本与边界写入本地证据包。
- `make evidence-ff-1-preflight` 生成完整前置证据包；suite verdict 为 `PASS`，但产品 Gate 与 FR-004/FR-011 仍为 `NOT_RUN`。
- `make evidence-ff-1` 在系统设备未发布时生成 `BLOCKED` verdict 并退出 2；这是 fail-fast 证据，不是失败日志噪音。
- `make evidence-ff-2-preflight` 生成绑定 source manifest 的 E0–E2 `PASS`，但 FF-2 及 FR-001/002/003 均保持 `NOT_RUN`。
- `make evidence-ff-2` 会保留机器 Gate 的 source manifest 与原始命令；真机/系统权限缺失时返回 `BLOCKED`/exit 2，机器子项通过但实体键盘未验收时返回 `HUMAN_GATE`/exit 3。
- 2026-08-29 历史实机基线：`0.9.6` 直刷版的 boot、serial-control、真实 BLE heartbeat、schema v3、默认静音、普通按键透传、Wi-Fi 音频、App 重启静音、设备端麦克风意图与录音红灯 HIL 通过。这些证据不自动继承给新分区布局。
- 2026-08-29 `0.10.0` 生产更新候选：macOS 68/68 tests、签名发布清单 contract、Ed25519 篡改拒绝、USB 安全顺序、版本防降级、双 OTA 分区、HTTPS 证书包、RSA-3072 签名固件与 rollback 构建已通过。由于用户当前不在设备旁，USB 迁移、OTA 断电回滚与升级后真实键盘/音频 HIL 保持待验收。

### Open questions / risks

- FF-0 与 FF-1 Stage B 隔离 preflight 已通过。历史 macOS build `26A5416b` 的 HAL 阻断保留为 FAIL；当前 `26A5421a` 已通过真实枚举、跨 UID PCM、停流静音和单次 reload。重载前必须精确清理本产品遗留的 broker socket/lock，安装脚本已用 `--reload-coreaudio` 将该操作合并到一次授权。新 OS build 仍不能继承此 E3，需先跑最小对照。
- FF-2 的 macOS HID consumer 终态关联已经通过，但产品 Gate 仍停在实体键盘 human gate；一次 boot、一次 report 计数、serial Action 或界面上的 `KEYS OK` 都不足以独立宣称产品 PASS。
- M5Unified 0.2.21 的 legacy I²S 麦克风路径在 IDF 5.5.1 及本项目原 6.0.2 构建上会得到常量 `-8`；固件 manifest 当前限制为 `>=5.4.2,<5.5.0`。只有迁移到已验证的新 I²S channel API，或上游回归修复并在真机 PCM oracle 通过后，才能解除版本上限。
- Xcode 27 Beta 的测试运行器会输出一条 `IDELaunchSession` 内部 assertion warning；当前 build/test 退出码为 0，仍需在后续 Beta/正式版复核。
- 本机可用竖切不等于研究级产品 Gate 全部完成：实体键盘大样本、时钟漂移/丢包/路径切换故障注入、多 App 听感、多次 Core Audio reload 和长时 soak 仍是后续工作，不能用 host GREEN 或单次真机运行冒充。

## 历史直刷证据

`firmware-release.json` 与 `finalize-device.sh` 只记录已经完成实机验收的 `0.9.6` 基线，不是当前的生产分发入口，也不能用它宣称 `0.10.0` 已通过 HIL。新用户应使用 macOS App 的 USB 安装器，后续使用受签名发布清单约束的 OTA。
