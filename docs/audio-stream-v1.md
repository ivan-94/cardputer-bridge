# Cardputer Bridge 音频协议 v2：UDP 明文 PCM

音频数据面只使用 UDP 明文；不使用 TCP、AES、ChaChaPoly、音频密钥、nonce 或认证 tag。BLE 安全配对、Wi-Fi 网络认证、固件签名及 OTA 校验保持不变。

## 安全边界

仅在可信局域网使用。音频没有机密性或密码学完整性保护：能观察局域网流量的设备可能窃听或伪造音频。随机 session ID 只用于区分当前会话及过滤旧包，**不是身份认证**。UDP 校验和也不是安全认证。

## 数据格式

16 kHz、单声道、PCM16 little-endian；每帧 320 samples（20 ms）。

| 偏移 | 字节数 | 内容 |
| --- | --- | --- |
| 0 | 4 | ASCII `CBP2` |
| 4 | 1 | 版本 `2` |
| 5 | 1 | flags：muted=1、test=2、end=4 |
| 6 | 2 | header length=28 |
| 8 | 8 | session ID |
| 16 | 4 | sequence |
| 20 | 4 | capture sample index |
| 24 | 2 | frame samples=320 |
| 26 | 2 | payload bytes=640 |
| 28 | 640 | 明文 PCM；没有尾部 tag |

头部多字节整数为网络字节序。单帧 668 字节。稳态 UDP 数据报携带 5 帧前的副本和当前帧，共 1,336 字节，低于普通 IPv4 MTU 1500 对应的 1,472 字节 UDP payload 上限。副本在后续数据报中提供一次恢复机会，不保证恢复所有丢包。

## 建立与关闭

Mac 经已配对的 BLE 控制通道发送：

```json
{"v":1,"type":"audio_offer","transport":"udp","format":"pcm16le-v2","ip":"192.168.1.2","port":49152,"sid":"0123456789abcdef"}
```

不包含音频密钥。固件只接受声明 UDP 及上述 format 的 offer。旧 TCP 或加密 UDP offer 被拒绝；接收端拒绝旧 `CBS1` 包、错误长度和不同 session ID。

设备发送静音 test 包；Mac 收到同一候选端点连续三个有效 test 包后，经 BLE 回应 `audio_ready`。这只验证会话可达性，不验证 UDP 发送者身份。

停止时保留现有行为：排空已采集的有界队列，发送三次 end 标记，接收端结束该段录音并刷新尾部。控制链或 Wi-Fi 失效仍停止采集。G0/任意键停止及向 Mac 发送按键的逻辑不在本次变更中修改。

## 缓冲与观测

当前采集与播放策略：

- 固件采集队列 10 帧（200 ms），非阻塞 UDP 发送；遇到本地队列压力最多重试三次，每次让出 1 ms。
- Mac 保留 5 帧（100 ms）的 UDP 重排窗口，并在首次输出前积累 64 帧（1.28 秒）给系统麦克风。同步抓包在真实局域网中观察到 1.143 秒的入站空窗，随后数据完整补到；HAL 因此以 1.28 秒为有界蓄水目标，只在积压超过 1.32 秒时回落到该目标。生产者租约为 1.5 秒，仅用于崩溃后失效，不会在网络停顿时提前丢弃已缓冲的语音。该取舍明确优先保证录音内容完整，而不是交互级低延迟。
- 未恢复帧仍计入 `missing_packets`，采集溢出计入 `capture_overruns`；填充和冗余恢复不能冒充原始音频完整到达。
- 探针显式输出 `transport=udp`、`audio_format=pcm16le-v2`、`audio_encrypted=false`、`decoded_packets`。不再输出“解密包数”。

## 验证与部署边界

离线验证：

```sh
./scripts/build-host.sh
ctest --test-dir artifacts/build/host --output-on-failure
python3 -m unittest discover -s tests/contract -p 'test_audio*.py'
python3 -m unittest discover -s tests/contract -p test_live_audio_session.py
python3 tests/integration/verify_device_audio_policy.py firmware/components/device_audio/device_audio.cpp
```

Mac XCTest 覆盖明文字节、错误头/长度/会话、旧协议拒绝、冗余及重排。C++ 测试覆盖固件实际编码器和 offer 解析。编译或协议测试通过不等于录音可靠性通过。

2026-09-03 本地结果：C++ 13 项、Mac XCTest 98 项、音频契约 25 项、串口验证器离线测试 7 项均通过；设备音频静态策略检查通过，ESP32-S3 固件编译通过。修改前新增的明文包长度测试曾失败（旧包包含 tag），修改后通过。

构建日志：`/tmp/cb-udp-plain-xcode.log`、`/tmp/cb-udp-plain-firmware.log`。固件构建使用 `SDKCONFIG=/tmp/cb-udp-plain-sdkconfig` 和独立目录 `/tmp/cb-udp-plain-firmware`，仅作编译验证，未作为生产签名固件交付。

`scripts/verify_live_audio_session.py` 只接受 v2 UDP 探针及 50 fps 流；60 秒中帧速率下限为 49 fps，且不允许新增采集溢出、发送失败或接收缺帧。完整验收还需人耳确认实际语音质量，不能只看网络计数。

2026-09-04 本地 HAL 连续性验收连续两轮通过：每轮 10 秒、480,000 samples，网络接收最长停顿 1.186 秒，最终 PCM 最大零洞分别为 1.458 ms 和 1.708 ms，总零洞分别为 37.063 ms 和 41.542 ms；两轮的缺包、缺采样、ring drop 和 stream failure 增量均为 0。本地 App 与驱动已部署用于验收，未发布 GitHub release；此轮租约修复不需要再刷固件。

## Source Manifest

- 最终需求：用户于 2026-09-03 在本会话明确要求“不要用TCP了，加密也去掉”。
- 固件编码器：`../firmware/components/audio_transport/audio_packet.cpp`；实际发送端：`../firmware/components/device_audio/device_audio.cpp`。
- Mac 解码器：`../macos/Sources/CardputerBridgeCore/AudioDatagramV2.swift`；接收端：`../macos/Sources/CardputerBridgeApp/AudioReceiverController.swift`。
- 控制契约：`../firmware/components/control_protocol/control_protocol.cpp` 与 `../macos/Sources/CardputerBridgeCore/AudioControlMessage.swift`。
- 验证来源：`../tests/unit/audio_packet_test.cpp`、`../tests/unit/control_protocol_test.cpp`、`../macos/Tests/CardputerBridgeCoreTests/AudioDatagramTests.swift` 及上述命令。
- 待人工验收：实际听感、语音识别效果与 1.28 秒端到端延迟的可接受性。
