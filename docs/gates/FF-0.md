# FF-0：完整工具链 Gate

## 结论

**PASS（E0–E2，仅限构建与 host 验证）。** 当前机器能重复构建 Cardputer-ADV 固件、SwiftUI macOS App 和 Audio Server Plug-in bundle；独立探针能加载 Plug-in binary、调用 factory 并取得 `AudioServerPlugInDriverInterface`。

这个 Gate 只回答构建与 host 验证，不用来代表后来取得的系统麦克风、Cardputer 真机、BLE、Wi-Fi 或音频链路证据；这些能力由各自更高等级 Gate 判定。

## 单命令入口

```bash
make verify-ff-0
make evidence-ff-0
```

验证内容：

1. contract verifier 必须拒绝两个 known-bad fixtures；
2. C++ host domain 与 Swift reducer 的 fail-closed 测试通过；
3. ESP-IDF 5.4.2 构建 `esp32s3` 镜像，依赖锁固定 M5Unified 0.2.21 / M5GFX 0.2.28；
4. Xcode 27 Beta 构建并校验 arm64 SwiftUI `.app`；
5. clang 构建 arm64 `.driver`，校验 plist、Core Audio UUID、factory symbol，并通过 `dlopen`/`QueryInterface` 探针。

## 已知风险

- M5Unified 的 legacy I²S 麦克风路径在本项目原 IDF 6.0.2 构建上只产生常量 `-8`；当前 manifest 限制 `>=5.4.2,<5.5.0`，升级前必须以真实 Cardputer PCM oracle 重新取证。
- Xcode 27 Beta 的 XCTest runner 会输出一条内部 `IDELaunchSession` assertion warning，但本次测试和 bundle 校验成功。
- HAL Plug-in 当前已由 FF-1 的独立 E3 证据安装并发布；不能倒推为本构建 Gate 的证明。
- 固件构建目录使用用户持久化 ASCII 路径，以规避 ESP GCC specs 对中文工程路径的缺陷；canonical 源码仍留在书稿工程目录。
- 用户最终选择直接刷入；日常重刷仍不执行 `erase-flash`，并保留确切端口、镜像 hash 与恢复参数。

## Source Manifest

### Sources

- `../../../../specs/Cardputer-Bridge-实现-Spec.md` — FF-0、证据等级与 fail-fast 要求。
- `../../../../02a-Cardputer-构建-harness.md` — runner、外部 verifier、known-bad fixture 与证据边界方法。
- Xcode 27 Beta macOS 27 SDK `CoreAudio/AudioServerPlugIn.h` — HAL Plug-in 类型、接口与安装边界的本机事实源。
- `firmware/dependencies.lock` — ESP-IDF、M5Unified、M5GFX 的解析后版本事实。

### Implementation

- `firmware/` — Cardputer-ADV ESP-IDF/M5Unified 构建目标。
- `macos/` — XcodeGen 声明、SwiftUI App、Swift reducer 与 XCTest。
- `audio-plugin/` — HAL factory/interface 骨架、plist 与独立 factory probe。
- `harness/`、`scripts/`、`Makefile` — 外部 verifier、runner 与单命令入口。

### Evidence boundary

- 本 Gate 的最高结论为 E0–E2。
- 本地原始日志保存在 `artifacts/verification/`，默认不提交。
- E3 需要安装后的 Plug-in、IPC 和独立系统消费者；E4/E5 需要 Cardputer 真机和最终录音消费者。
