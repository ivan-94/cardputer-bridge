# Cardputer Bridge Harness Protocol v1

开发控制面使用一行一个 JSON object 的 NDJSON。实现端报告事实，外部 verifier 负责判定。

## Action

- `toggle_mic_intent`：切换用户开麦意图；是否打开采集仍由授权公式决定。
- `control_link_lost`：认证控制链失效，必须清除 live intent 并关闭 capture gate。

## Source

- `harness`：来自测试控制面，只证明应用行为路径。
- `ble_control`：来自 BLE 控制链生命周期。
- 后续 `keyboard`：来自真实 Cardputer 键盘适配器，才可作为物理输入的 E4 证据。

## Event

当前 host tracer 输出：

```json
{"v":1,"event":"transition","action":"control_link_lost","source":"ble_control","mic_intent":"muted","capture_gate":"closed","ble_control_authenticated":false,"wifi_audio_authenticated":true,"virtual_mic_ready":true}
```

`transition`、`command`、`snapshot` 与 `error` 的 v1 schema 已固定在 `harness/schemas/`；字段只能向后兼容增加，不能静默改变既有语义。

## 外部控制面

Host Harness 从 stdin 接收 NDJSON；它不能直接改 `BridgeState`，只允许调用与真实适配器相同的 `reset()` 和 `dispatch()`：

```json
{"v":1,"command":"reset","profile":"ready_muted","request_id":"reset-1"}
{"v":1,"command":"dispatch","action":"toggle_mic_intent","source":"harness","request_id":"dispatch-1"}
```

每个 reset 返回完整 `snapshot`，每个 dispatch 返回 `transition`。无法解析或不允许的 Action 返回 `error` 且进程最终非零退出。正式 schema 位于 `harness/schemas/`；`host-scenario.ndjson` 是可重复的 golden command stream。
