# FF-1 macOS 27 HAL 运行时实验证据

## Verdict

- 当前 FF-1 E3 核心数据路径：`PASS`。升级至 macOS 27.0 build `26A5421a` 后，产品 Driver 可安全枚举并发布 `Cardputer Microphone`；独立系统 consumer 捕获合成 pulse，producer 的共享读指针真实推进，停止与 consumer 重启后输出数字静音。
- 旧 Beta `26A5416b` 的最小 A/B 仍保留为历史 `FAIL`，它解释了当时为何 fail fast，不再代表当前运行时状态。
- 产品声明边界：真实 Cardputer→App→Driver→系统 consumer 已跑通，一次精确清理 stale broker endpoint 后的 `coreaudiod` reload 已恢复枚举、App bridge 和系统 PCM；重复 reload、30 分钟 soak、Audio MIDI Setup/浏览器/会议 App 和听感仍为 `NOT_RUN`，因此整个 FF-1 尚未完成。

## 环境与构建身份

| 项 | 值 |
| --- | --- |
| 机器 | 用户当前 Apple Silicon Mac |
| macOS | 27.0, build `26A5416b` |
| Xcode | Xcode Beta 27.0, build `27A5228h` |
| 实验开始时基线 commit | `511311440061610ce2a12c3928afc089abef0a2f` |
| 固化修复 commit | `d6e71ae86ab8fbe4997de456d394038b6cac1203` |
| 当前正常 Driver 构建 SHA-256 | `c5e94999aa2545f45722b40c869340a4aaab9737a6ee81074c8ed7b719630f5a` |

当前重跑环境为 macOS 27.0 build `26A5421a`；已安装 Driver 与本地构建的 SHA-256 均为上表所列值。

## A/B 观测

| 对象 | 只读枚举 | `coreaudiod` | 结论 |
| --- | --- | --- | --- |
| Cardputer Driver 诊断版 | `audio_device_probe --list` 超时 | 约 139% CPU | 产品 Driver 在当前运行时失败 |
| ad hoc 签名 Cardputer Driver | exit `124` | 120–139% CPU | 签名不是根因 |
| Apple NullAudio 最小对照 | exit `124` | 107–136% CPU，60 秒未恢复 | 问题不是 Cardputer IPC 特有 |
| Initialize 立即返回错误 | 仍可触发高 CPU | 持续高 | “失败关闭 Driver”不是安全隔离 |
| 无 Plug-in 声明占位 bundle | 短暂可枚举，后续再现 | 高 CPU | 仅修改 `Info.plist` 不足以隔离 |
| 完整移出 Cardputer `.driver` | 约 15 分钟后枚举通过 | 0.0% CPU | 当前安全系统状态 |

高 CPU 时，测试 producer 能连接 broker，但输出 `FAIL no consumer advanced shared read index`，即 `consumed_frames=0`。因此不能把设备名可见或 broker 可连接当作真实 IO 成功。

## Beta 7 重跑与当前证据

| 断言 | 观测 | 判定 |
| --- | --- | --- |
| 系统输入发布 | `Cardputer Microphone`，48kHz、mono、Float32 | PASS |
| 独立 consumer 获取合成 PCM | 144000 帧，`active_peak=0.5` | PASS |
| 系统确实消费共享 ring | producer 观察 `consumed_frames=28612` | PASS |
| producer 停止后静音 | capture `tail_peak=0` | PASS |
| consumer 重启初态 | 4800 帧，`active_peak=0`、`tail_peak=0` | PASS |
| 真实硬件数据链路 | 5.4.2 固件下 10 秒系统录音 `active_peak=0.826172`、静音尾部 0 | PASS |
| reload/30 分钟 soak/三个常用 App | 尚未执行 | NOT_RUN |

真实硬件验证还给出了跨层反例：ESP-IDF 6.0.2 下 UDP、认证与 Driver 都正常，但 live PCM 只有固定 `-8/32768`；切换同一设备至 5.4.2 后，480000 帧捕获中有 142092 帧非零、512 个不同非零值，范围 `[-0.159424, 0.826172]`。这证明系统链路不应只断言“非零”，还必须拒绝单一 DC 常量。

## 稳定可重读产物

- Apple NullAudio 源码 commit：`88460220d88e9d5f2230bcbc5f11a0655f351dd5`（commit subject `Republish sample code project.`）；`NullAudio.c` SHA-256 `8b61fb9f96c12356c7da6696a6c1bee5da73222dfb4e831aa9487244e7bf5dfc`。
- 已安装过的 NullAudio 对照二进制可恢复备份：`/Users/ivan/.local/share/cardputer-bridge/backups/audio-plugin/20260827T222702Z-91544/CardputerBridgeAudio.driver`；executable SHA-256 `2142d563cc59781757e437f54a0adc39f9e6d3042f9266de768bc438e59d69f6`，`strings` 可观察 `NullAudioDevice_UID` 和 `com.apple.audio.NullAudio`。
- ad hoc 签名 Cardputer 诊断版备份：`/Users/ivan/.local/share/cardputer-bridge/backups/audio-plugin/20260827T223241Z-92607/CardputerBridgeAudio.driver`；executable SHA-256 `d88bbd9543c6aeeb8b06e8b0d6f50bcec531ed7f268b02907f70ee2ec067f9f1`。
- 最后移出 HAL 的 bundle 备份：`/Users/ivan/.local/share/cardputer-bridge/backups/audio-plugin/20260827T224610Z-runtime-quarantine-95643/CardputerBridgeAudio.driver`。
- 当前 HAL 事实：`/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver` 已安装，Driver SHA-256 为 `c5e94999aa2545f45722b40c869340a4aaab9737a6ee81074c8ed7b719630f5a`。

## 无系统写入的复核命令

```bash
sw_vers
shasum -a 256 /Users/ivan/.local/share/cardputer-bridge/build/audio-plugin/CardputerBridgeAudio.driver/Contents/MacOS/CardputerBridgeAudio
./scripts/check-audio-hal-runtime.sh
python3 tests/integration/verify_audio_device_probe.py /Users/ivan/.local/share/cardputer-bridge/build/audio-plugin/audio_device_probe
test -e /Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver
```

当前脚本只允许精确验证过的 build `26A5421a`；其他 macOS build 仍须先从 Apple 最小 sample 开始，并将原始命令、stdout/stderr、进程 CPU 序列和 bundle hash 直接收入 evidence bundle。

## Source Manifest

### Sources

- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) — NullAudio 最小 sample 与 HAL 安装路径。
- [Espressif esp-idf#18621](https://github.com/espressif/esp-idf/issues/18621) — Cardputer-ADV/ES8311 在 IDF 5.5.1 返回常量 `-8`、5.4.2 正常的上游复现与 workaround。
- `../../../../specs/Cardputer-Bridge-实现-Spec.md` — FF-1 验收标准、证据等级与退出码语义。
- `../../../../02a-Cardputer-构建-harness.md` — 外部 verifier、可证伪和真实边界原则。
- 2026-08-28 用户授权的本机 HAL 安装/reload 实验及随后的只读恢复复核。

### Produced artifacts

- 本报告。
- `../../scripts/check-audio-hal-runtime.sh`、`../../scripts/verify-ff-1.sh` 与 `../../scripts/verify-ff-1-preflight.sh`。
- `../../tests/integration/verify_audio_hal_runtime_policy.py` 与 `../../tests/integration/verify_ff1_runner.py`。
- 上述用户目录中的可恢复 bundle。

### Key decisions

- 仅允许已验证的精确 macOS build 运行 legacy Cardputer HAL bundle；未知 build 继续 fail fast。
- 未验证 macOS build 的安全状态是从 HAL 完整移出，不是保留一个“失败关闭”或修改 `Info.plist` 的 bundle；当前精确验证的 `26A5421a` 允许安装。
- 旧 Beta E3 保留为历史 `FAIL`；Beta 7 的系统发布、合成 PCM、真实 PCM、fail-silent 和单次 reload 核心路径记为 `PASS`，重复 reload/soak/多 App 保持 `NOT_RUN`。

### Verification evidence

- 隔离 suite：`AUDIO_FACTORY_PROBE_PASS`、`AUDIO_DRIVER_HAL_PUBLICATION_SCAN_PASS`、`PASS audio_ipc_pulse_stop_crash_lease_and_restart` 连续 3 次、`PASS audio_fd_broker_full_product_seam`。
- 恢复后只读 suite：`PASS audio_device_probe_lists_rejects_missing_and_reports_running_state`；10 秒后 `coreaudiod` 0.0% CPU。
- Beta 7 FF-1 核心 runner：合成 PCM `active_peak=0.5`、`tail_peak=0`，producer `consumed_frames=28612`；重启 consumer 后全零。
- 真实链路：IDF 5.4.2 下 HIL `sent_growth=217`、`accepted_growth=219`、失败/溢出为 0；系统 PCM `active_peak=0.826172`、静音尾部 0。
- v3 reload 复核：构建与 HAL 已安装二进制 SHA-256 同为 `646104d644e2f8c978a3ea62f4f7d1e9fdc8d64184d4eb28d2f32d39f2dcdaf5`；精确清理 `/tmp/io.nexu.cardputerbridge.audio-v1.sock{,.lock}` 后重载 `coreaudiod`，新 endpoint 由 `_coreaudiod` 重建，设备枚举、`system_microphone_ready=true`、`make verify-phase-3`、重启静音 PCM 和 UI AX oracle 全部通过。

### Open questions / risks

- 当时的原始终端输出没有以完整 evidence bundle 保存；本报告因此只固化已观察数值、二进制/源码身份、恢复结果和可安全重跑命令。下次 E3 必须由 `artifacts/verification` runner 直接采集。
- 设备重启后 App 曾保留旧 authenticated packet 计数，第一次验证因 `audio_receiver_ready=false` 按 fail-silent 录到全零；现已新增 stale-authenticated-session rotation 与 Core test。不重启 App 的真实重刷把 session `2370…` 自动轮换为 `c31c…` 并恢复 `audio:ready`，后续 4 秒 HIL 本次 UDP 失败/采集溢出增长均为 0。
- 该次 Beta 7 初始取证时 16kHz→48kHz 仍使用 3× sample-hold；后续产品路径已换为 `AVAudioConverter` 高质量重采样、60ms 启动水位/40ms 重排的 jitter buffer、1.25× 增益/软限幅和丢旧追新的 v3 SPSC ring。积压 3 秒后启动系统 consumer 的真机声学延迟上界为 156.1ms；最终人类听感、时钟漂移和丢包注入仍未完成。
