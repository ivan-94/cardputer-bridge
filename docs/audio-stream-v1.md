# Cardputer Bridge Audio Stream v1

## 目标

Cardputer 的 16 kHz 单声道 PCM 必须连续进入 macOS 系统麦克风。正常局域网下不接受静默丢帧；网络短暂抖动时，优先由传输层重传，而不是把缺失语音交给上层猜测。

## 做的减法

- 只保留一条有序 TCP 音频流，不再维护 UDP 重排窗口。
- 固定使用 10 ms 音频帧，不再用 20 ms 帧放大单次丢失的语音长度。
- 采集任务只复制固定长度 PCM 到无分配 SPSC ring；连接、加密和发送全部由低优先级传输任务完成。
- macOS 只保留 30 ms 启动储备，稳态帧立即交给 Core Audio。
- UI 和运行探针最多每 100 ms 发布一次，不再跟随每个音频帧刷新。
- BLE 状态只保留产品状态；发送计数、失败计数等诊断信息只走串口 harness。

## 传输契约

- 控制面 offer 必须声明 `"transport":"tcp"`。
- 一个音频 session 只有一条已认证的 active connection。候选连接必须先连续通过 3 个 muted test frame 的 AES-GCM 验证，且 sequence 不得早于当前流，才能原子替换旧连接。
- 每个加密帧固定 364 字节：28 字节认证头、320 字节 PCM16、16 字节 AES-GCM tag。
- magic 为 `CBS1`，采样率为 16 kHz，每帧 160 samples。
- sequence 在采集时分配。采集 ring 满时仍消耗 sequence，因此接收端能观察到真实采集缺口。
- TCP 启用 `TCP_NODELAY`；任一 socket 选项配置失败都会终止连接。单次发送阻塞最多 200 ms，TCP 内核发送队列约 80 ms。采集 ring 固定 20 帧，最多保存 200 ms，满时显式增加 `capture_overruns`，不阻塞麦克风采集。

## 失败语义

- TCP、加密或连接失败增加 `stream_failures`，关闭 receiver-ready，并触发重新连接。
- sequence 缺口增加 `missing_packets`；只做短淡出静音填充，避免爆音，不把填充伪装成成功传输。
- 旧帧或重复帧增加 `duplicate_or_late_packets` 并丢弃。
- 缺帧和重复帧计数贯穿整个 session，静音或 TCP 重连不能清空证据。
- 控制链、Wi-Fi 或 receiver-ready 任一失效，采集立即停止并清空有界 ring。
- runtime probe 每 2 秒续活；帧路径的 UI、probe 和错误发布统一受 100 ms 节流。

## 验证门禁

自动门禁：

```sh
./scripts/build-host.sh
ctest --test-dir artifacts/build/host --output-on-failure
python3 -m unittest tests.contract.test_audio_task_scheduling
python3 tests/integration/verify_device_audio_policy.py \
  firmware/components/device_audio/device_audio.cpp
./scripts/build-firmware.sh
./scripts/verify-macos.sh
```

真实设备门禁使用 `scripts/verify_audio_hil.py`。稳定 2.4 GHz 局域网中连续录音至少 60 秒，必须同时满足：

- 有效帧速率不少于 90 frames/s；
- `missing_packets` 增长为 0；
- `duplicate_or_late_packets` 增长为 0；
- `stream_failures` 增长为 0；
- `capture_overruns` 增长为 0；
- 发送端与接收端帧增量差不超过 2；
- 静音后发送计数停止增长。

端到端声学延迟仍需在实机上单独测量，不能用“TCP 已连接”代替延迟证据。

## Source Manifest

- 用户在 2026-09-01 确认的第一性原理减法与可靠传输实施计划。
- `../../../02a-Cardputer-构建-harness.md`：可控、可观测、可验证的硬件 harness 原则。
- `firmware/components/device_audio/device_audio.cpp`：采集与传输任务实现。
- `macos/Sources/CardputerBridgeApp/AudioReceiverController.swift`：macOS TCP receiver 与运行探针实现。
- `scripts/verify_audio_hil.py`：跨固件、网络、App 与虚拟麦克风的实机门禁。
