# LANDrop iOS 2.8.2 修复包（TrollStore）

## 当前状态

已完成面向 **TrollStore 2.x** 的补丁源码、macOS 构建脚本、GitHub Actions 工作流、静态校验和文档。当前 Windows 工作区没有 Xcode/Flutter，最终 IPA 由 GitHub Actions 的 macOS runner 编译产出，安装包本身不做签名（ad-hoc），TrollStore 安装时自行完成 CoreTrust bypass。

解密后的 `LANDrop_2.8.2.ipa`（`Runner` 与 Share Extension 均 `cryptid=0`）作为草稿 Release 的 asset 挂在版本 tag 上，不提交进 Git 历史。

## 输入 IPA 的要求

工作区里的 `LANDrop-2.8.2.ipa` 必须是真正解密过的包。TrollStore 遇到加密主二进制会报 **180**，嵌套框架仍加密会报 **184**，而 GitHub Actions 的 macOS runner 不能离线解密 FairPlay。

- `Runner` 的 `cryptid=0`，且原 `0x5000` 页是真实 ARM64 明文，而不是只把 `cryptid` 清 0；
- 所有保留的嵌套 Mach-O 都无 `cryptid=1`。

本补丁会用全新的未加密 Share Extension 可执行体替换原 appex，所以不要求你先解密 appex；Runner 必须解密。`tools/check_decrypted_ipa.py` 会比较两个 4 KiB 页，确认不是“假解密”。

## 文件

- `ANALYSIS.md`：逆向证据、两个 bug 成因、二进制补丁与巨魔签名机制的完整分析。
- `patches/ios/Share Extension/ShareViewController.m`：新的纯 ObjC 分享扩展，修复系统截图分享。
- `patches/ios/Share Extension/main.m`、`ShareExtension.h`：扩展入口与类名/枚举声明。
- `tools/patch_bluetooth_plugins.py`：对两个未加密蓝牙插件各打 4 字节，关闭 power alert 默认值。
- `tools/check_share_nib.py`：确认原 NIB 的 42 字节 Swift 类名及长度前缀未被破坏。
- `tools/check_decrypted_ipa.py`：验证输入是真正 decrypted、TrollStore 可装的 IPA。
- `tools/prepare_entitlements.py`：生成两份字面值 entitlements，保留 App Group 与原受限 capability。
- `tools/verify_patched_ipa.py`：检查输出 IPA 的补丁、签名、entitlements、NIB、DRM 元数据（`SC_Info` / `ITSDRMScheme`）。
- `tools/macho.py`、`tools/check_patch_sources.py`：共用 Mach-O 解析与 Windows 可跑的静态检查。
- `scripts/build_patched_ipa.sh`：macOS 下编译 appex、打补丁、ad-hoc 签名并输出 IPA。
- `.github/workflows/build-ios.yml`：手动触发的 macOS-14 编译验证工作流，含输入 IPA 与构建缓存。

蓝牙补丁不再新增 framework，也不向 `Runner` 注入 `LC_LOAD_DYLIB`；分享修复不再修改 storyboard NIB。这两处改动都降低了对 FairPlay/CodeDirectory 与 NIBArchive 格式的影响。

## 本地静态检查

```bash
python tools/check_patch_sources.py
bash -n scripts/build_patched_ipa.sh
```

若已有解密 IPA，还可在 Windows 上做结构检查：

```bash
python tools/check_decrypted_ipa.py LANDrop-2.8.2-decrypted.ipa LANDrop-2.8.2.ipa
```

## 在 macOS 本地构建

需要 Xcode 命令行工具，不需要开发者证书：

```bash
INPUT_IPA=/path/to/LANDrop-2.8.2-decrypted.ipa \
ORIGINAL_IPA=/path/to/LANDrop-2.8.2.ipa \
bash scripts/build_patched_ipa.sh
```

输出 `LANDrop-2.8.2-fixed-trollstore.ipa`。脚本会 ad-hoc 签名 Runner / Share Extension / 嵌套框架；TrollStore 安装时会自动保留 entitlements 并应用 CoreTrust bypass。

## GitHub Actions 构建

工作流是**仅 `workflow_dispatch` 手动触发**，且必须从 **tag** 运行：在 Actions 的 “Use workflow from” 选中 tag 后，工作流会从该 tag 的草稿 Release 下载解密 IPA（默认资产名 `LANDrop_2.8.2.ipa`）。加密原包和 decrypted IPA 都保留在 `.gitignore` 中，不会提交进 Git；它们只作为草稿 Release asset 上传。

重复运行同一 tag 会复用下载与编译缓存；成功后从 Artifacts 下载 `LANDrop-2.8.2-fixed-trollstore-<tag>`。

## TrollStore 安装与真机验证

1. 用 TrollStore 2.x 打开输出 IPA 安装；不要出现错误 180。若出现 184，检查输入 IPA 是否仍有加密的嵌套 Mach-O。
2. 关闭蓝牙后冷启动 LANDrop，应不再出现「打开蓝牙」系统提示。
3. 截图预览 → 分享 → LANDrop，应进入发送流程并自动选中该截图；相册图片/视频、Files 的 PNG/JPEG/HEIC 分享无回归。
4. App Group 必须同时存在于 Runner 和 Share Extension 的签名 entitlements：

```text
group.app.landrop.landrop-flutter
```

5. 若截图分享仍失败，App Group 内的 `Library/Logs/landrop-share.log` 会记录每个 provider 走了哪种表示、复制与图片规范化结果，据此定位是载荷问题还是宿主未响应。

## 关于“改成设置中的选项”

当前 IPA 的 Flutter UI 已编译为 AOT 快照，且业务源码不在工作区，无法可靠地向现有设置页新增开关。因此按备选方案直接关闭强制弹窗。若以后取得完整 `landrop_flutter` 源码，可在设置页加开关，并在源码层调用 `FlutterBluePlus.setOptions(showPowerAlert:)` / 修改 `flutter_ble_peripheral` 的硬编码 `true`；届时就不需要二进制补丁。
