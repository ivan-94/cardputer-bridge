# FF-1：系统虚拟麦克风 Gate

## 当前 verdict

- Preflight Stage B：`PASS`。Driver-owned anonymous buffer、Unix `SCM_RIGHTS` fd broker、双方 `getpeereid` 身份合同和隔离 E0–E2 验证均已通过。
- macOS 27.0 build `26A5421a` 的产品核心路径：`PASS`。系统发布 48kHz/mono/Float32 `Cardputer Microphone`；独立 consumer 捕获合成 pulse，producer 读指针推进，停止与 consumer 重启后为数字静音；真实 Cardputer PCM 也已穿过 App/Driver 被系统 consumer 捕获。
- 整个 FF-1：仍为 `NOT_COMPLETE`。driver reload、30 分钟 soak、Audio MIDI Setup/浏览器/会议 App 与用户听感尚未执行。
- 旧 build `26A5416b` 的 Cardputer/NullAudio 枚举挂起保留为历史 `FAIL`；精确 build allowlist 继续让未知 macOS 版本 fail fast。

## 可复现入口

```bash
make verify-ff-1-preflight
make evidence-ff-1-preflight

# 在已验证的精确 macOS build 上运行核心 E3；未知 build 返回 BLOCKED / exit 2
make verify-ff-1
make evidence-ff-1
```

Preflight Stage B 包含：

1. 校验 `harness/contracts/ff-1.json` 完整性；
2. 用 known-bad contract 证明 verifier 会 RED；
3. 通过 Plug-in 自身的 AudioServerPlugIn 公开接口验证设备发布、48kHz/mono/Float32 格式、必需属性面、时钟和欠载数字静音；
4. 验证 Driver-owned anonymous buffer + Unix fd broker：consumer-first 初态静音、`SCM_RIGHTS` fd 传递、双向 `getpeereid` UID 拒绝、生命周期 `flock` 防止两个 broker split-brain、活跃/启动中/恶意占位路径不被删除、短协议头/多 fd/截断 ancillary 消息不泄漏 fd、损坏 ring 索引静音、producer stop/crash 后 350ms 内静音、producer restart 恢复；这些是同 UID 测试 seam，不冒充真实 uid 501→202；
5. 构建独立 Core Audio PCM consumer；在已验证系统上应检查不存在的输入设备会 `BLOCKED` 且不生成伪证据，当前 macOS 27 为避免重现 daemon spin 而 `NOT_RUN`；
6. 以独立 PCM metrics/raw verifier 检测 pulse 的确定序列、拒绝随机噪声/NaN，并检测 tail 数字静音；
7. 在临时 HAL root 测试“无明确确认不写入、重复安装幂等、拒绝 symlink escape、失败回滚、卸载移入可恢复备份”。

`coverage.json` 必须逐项表达：系统设备、合成/真实 PCM 和断流静音已有 PASS；reload、30 分钟 soak 与多 App/听感保持 `NOT_RUN`。在这些必需断言补齐前，聚合 FF-1 不得写成完整 PASS。

## Fail-fast 与系统变更停止线

安装脚本默认退出 2；只有显式传入 `--confirm-system-change` 才会写入目标目录。它会在替换同名 bundle 前移入持久备份，卸载也只移入可恢复备份，不直接删除。

`scripts/check-audio-hal-runtime.sh` 只允许已验证的精确 build `26A5421a`；其他 build 在安装与 Core Audio 枚举之前 exit 2。安装器的 `REMOVE_FROM_HAL` 指令只会把本项目 Driver 移入用户目录备份，不删除其他 HAL bundle。

## 声明边界

当前 E3 已证明真实 App/Driver 跨进程 bridge、bundle 注册、系统 consumer 与 fail-silent 核心路径。它仍不证明 reload、30 分钟稳定性、三个常用 App、最终重采样音质或用户听感；这些必须由后续 E3/E5 证据回答。

## Source Manifest

- `../../../../specs/Cardputer-Bridge-实现-Spec.md` — FF-1 通过标准、Gate contract、E0–E5 声明边界和当前 macOS 27 停止线。
- `../../../../02a-Cardputer-构建-harness.md` — 可控制、可观察、可判定和外部 verifier 原则。
- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) — HAL Plug-in 的官方实现路径。
- [Espressif esp-idf#18621](https://github.com/espressif/esp-idf/issues/18621) — Cardputer-ADV/ES8311 在 IDF 5.5.1 返回常量 `-8`、5.4.2 正常的上游复现。
- 2026-08-28 本机 A/B 证据 — macOS 27.0 `26A5416b`；Cardputer/签名/失败关闭/Apple NullAudio 均出现枚举 timeout 与 daemon 高 CPU；producer 观察 `consumed_frames=0`；隔离 runner 观察 `AUDIO_FACTORY_PROBE_PASS`、`AUDIO_DRIVER_HAL_PUBLICATION_SCAN_PASS`、`PASS audio_ipc_pulse_stop_crash_lease_and_restart`、`PASS audio_fd_broker_full_product_seam`。
- `../evidence/FF-1-macOS-27-runtime-2026-08-28.md` — 稳定环境、commit、源码/二进制 hash、A/B 表、恢复结果、可安全复核命令与局限。
- 2026-08-28 Beta 7 重跑 — 合成 PCM `active_peak=0.5`、producer `consumed_frames=28612`、重启静音峰值 0；真实 IDF 5.4.2 链路 10 秒 PCM `active_peak=0.826172`、静音尾部 0。
