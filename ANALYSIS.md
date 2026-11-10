# LANDrop iOS 2.8.2 修复分析（TrollStore 版）

本目录保存对 `LANDrop-2.8.2.ipa` 的逆向证据、两个 bug 的修复以及远程编译验证流程。原 Flutter/Dart 业务源码没有公开，IPA 里只有已编译的 AOT 快照，因此修复以“原生二进制补丁 + 原 AOT/资源”为目标，输出供 TrollStore 2.x 安装的 IPA。约束：**不需要开发者证书、不需要 provisioning profile，由 GitHub Actions 编译产出**。

## 从原 IPA 确认的事实

- Bundle ID：`app.landrop.landrop-flutter`；版本 `2.8.2 (34)`；Xcode 16 / iOS 18 SDK。
- Flutter `3.22.3` / Dart `3.4.4`；主 App URL scheme：`SharingMedia-app.landrop.landrop-flutter`。
- App Group：`group.app.landrop.landrop-flutter`。
- 插件精确版本：`flutter_blue_plus 1.32.12`、`flutter_ble_peripheral 1.2.5`、`flutter_sharing_intent 1.1.1`。
- `Runner` 的 `LC_MAIN.entryoff=0x5160` 落在 FairPlay 加密页 `0x5000–0x6000` 内；`LC_ENCRYPTION_INFO_64: cryptoff=0x5000, cryptsize=0x1000, cryptid=1`。该页熵 7.957，入口字节不是合法 ARM64 序言。
- Share Extension 原可执行体同样有 `cryptid=1`，加密页 `0xc000–0xd000`，入口在 `0xc2d0`。本方案会直接替换它，因此**不要求输入 IPA 解密 appex**。
- 25 个嵌套 framework（含 `App.framework/App`）本来就是 `cryptid=0`。
- 原 `Runner` entitlements 含 Team `JAQBXTUN25`、App Group、`com.apple.developer.networking.multicast` 和 `com.apple.developer.device-information.user-assigned-device-name`；appex entitlements 含相同 App Group。两者都必须在重签时保留。
- 原 storyboard NIB 是 `NIBArchive`，`UIClassSwapper` 用长度前缀 `0xAA` 保存 42 字节类名 `_TtC15Share_Extension19ShareViewController`。

## 为什么不能直接用当前 App Store IPA

TrollStore 2.x 安装时会对每个 Mach-O 调用 `apply_coretrust_bypass()`；主二进制若 `cryptid=1`，直接返回错误 **180**（“encrypted main binary”），嵌套加密二进制返回警告 **184**。它不读取 `SC_Info/sinf` 走 App Store FairPlay 密钥流程；保留 `cryptid=1 + sinf` 也无济于事。

GitHub Actions 的 macOS runner 没有授权 Apple ID/设备密钥袋，也没有可运行并 dump 原 App 的 iOS 进程，**不能离线解密 FairPlay**。因此：

1. 用户须在能合法运行原版 2.8.2 的设备上，用 TrollDecrypt / bagbak / appdecrypt / frida-ios-dump 等导出真正 decrypted IPA。
2. 解密不是把 `cryptid` 改为 0；必须把 `0x5000` 那 4 KiB 的明文写回 Runner 相同偏移。校验工具会比较原加密页与输入页，要求两者不同且新页不是高熵密文。
3. Actions 只做确定性补丁、重编译 appex、ad-hoc 签名、打包和结构验证。

## Bug 1：启动时蓝牙系统弹窗

这不是 `NSBluetoothAlwaysUsageDescription` 权限弹窗，而是 CoreBluetooth 的 power alert。

- `flutter_blue_plus 1.32.12` 在 `+[FlutterBluePlusPlugin registerWithRegistrar:]` 中把 `showPowerAlert = @(YES)`，创建 `CBCentralManager` 时传入 `CBCentralManagerOptionShowPowerAlertKey`。
- `flutter_ble_peripheral 1.2.5` 在 Swift `FlutterBlePeripheralManager.init` 里硬编码 `CBPeripheralManagerOptionShowPowerAlertKey: true`。
- 两者都在插件注册期、早于 Dart `main()`，所以 Dart 侧 `setOptions(showPowerAlert: false)` 不可靠；Info.plist 也没有全局开关。

初版曾设计 `LANDropPatches.framework` + `LC_LOAD_DYLIB` + Objective-C `+load` swizzle；后台静态审查和本地字节复核后已放弃，因为：

- 必须修改 Runner 的 Mach-O 头，把本可避免的 FairPlay/CodeDirectory 风险引入补丁链路；
- 多一个 framework、rpath、签名实体和 CodeResources 维护面；
- 两个插件的默认值可以直接在各自未加密 dylib 的 `__TEXT` 立即数上关闭。

最终 `tools/patch_bluetooth_plugins.py` 做两处带指纹断言的 4 字节补丁：

| 文件 | 偏移 | 原指令 | 新指令 | 作用 |
|---|---:|---|---|---|
| `flutter_blue_plus` | `0x4270` | `mov w2,#1` (`22008052`) | `mov w2,#0` (`02008052`) | 默认生成 `@NO` |
| `flutter_ble_peripheral` | `0x4588` | `mov w8,#1` (`28008052`) | `mov w8,#0` (`08008052`) | Swift `Bool true` 变 `false` |

补丁前会断言紧邻的 `bl numberWithBool:` / `strb` 指纹、Mach-O 类型以及 `cryptid=0`，不匹配就中止。`flutter_blue_plus` 的 Dart `setOptions` 字符串只在 AOT 符号池中出现，未见业务调用参数；CoreBluetooth manager 在首个 method call 时初始化，默认 `@NO` 已生效。若以后取得完整 Flutter 源码并显式调用 `setOptions(showPowerAlert:true)`，应同步移除该调用或改为源码级开关。

## Bug 2：系统截图分享只闪一下

原 `flutter_sharing_intent 1.1.1` 的 `ShareViewController.swift` 对图片只做：

1. `hasItemConformingToTypeIdentifier(UTType.image.identifier)`；
2. `loadItem(forTypeIdentifier:"public.image")`；
3. 强制 `data as? URL`；
4. `FileManager.copyItem` 到 App Group。

系统截图预览的 `NSItemProvider` 常提供 `UIImage`/`NSData`、具体 UTI（`public.png/jpeg/heic`）或短暂存在的临时 URL；相册通常才给可复制的 file URL。旧逻辑转换或复制失败就 `completeRequest`，于是界面一闪而过。加 `NSExtensionActivationRule` 的 `public.png/public.jpeg` 是错误方向，图标本来就已出现。

新实现是纯 Objective-C 的 `patches/ios/Share Extension/ShareViewController.m`：

- 类名声明为 `_TtC15Share_Extension19ShareViewController`，与原 NIB 中 `UIClassSwapper` 查找的 Swift mangle 名完全一致，**NIB 保持原样**；早期“替换成长类名 + NUL 补齐”的做法会破坏 NIBArchive 长度前缀编码，已删除。
- 图片按 `loadFileRepresentation` → `loadInPlaceFileRepresentation` → `loadDataRepresentation` → `loadItem` 四级回退，覆盖 png/jpeg/heic/heif/tiff/gif/webp/public.image；`NSURL`、`UIImage`、`NSData` 都接受。截图场景恰恰是 provider 不肯为 `loadFileRepresentation` 落地临时文件的那种，`loadInPlace` 这一级是为它加的。
- 截图打上标记后（标注/涂鸦）系统把内容作为**内存 UIImage** 交给扩展，请求文件表示时序列化成 `NSKeyedArchiver` 的 `bplist00` 归档，文件名却还是 `.png`。旧逻辑把归档原样复制过去，宿主拿到的是打不开的“图片”。新增 `LANDropNormalizeImageFileAtURL` 在复制后就地修复：先按签名判断（PNG/JPEG/GIF/TIFF/HEIC/RIFF），不是真图片且是 bplist 时用 `NSKeyedUnarchiver` 还原成 `UIImage`/`NSData` 再重写成 PNG；解档失败则扫描原始字节里的 PNG IEND / JPEG EOI 边界提取图像；仍失败才放弃这一路表示、继续尝试下一种，绝不把不可用的文件交给宿主。整个修复过程 `@try/@catch` 包裹，异常不会终止扩展进程。
- 复制顺序与原版一致：`NSFileCoordinator` 优先、直接 `copyItem` 兜底。相册的 security-scoped URL 正是走协调复制这条已经验证可用的路径，顺序不能反过来。
- 载荷交接只做原版那一次 `UserDefaults(suiteName:)` 写入，**不**绕过 cfprefsd 直接写 App Group 的 `Library/Preferences/<group>.plist`。那个文件归 cfprefsd 管，直写会和它的缓存互相覆盖，宿主读该域时拿不到键，表现就是「App 打开了但什么都没选中」。写入后立刻用宿主同一套 API 回读校验，读不到就判交接失败并写日志，不再假装成功去开 App。
- 落地文件名只保留 `[A-Za-z0-9._-]`，其余字符替换为 `_`。宿主插件是把 `file://<path>` 直接字符串替换成路径、**不做百分号解码**，截图默认名 `PNG image.png` 这类带空格/中文的名字会让路径失效、图片被静默丢弃。
- 若某个 provider 第一次取载荷为空（截图标注进程交付较慢），整套流程重试一次再判定失败。
- 公开 UTI 全不匹配的第三方/私有 provider，改用 `registeredTypeIdentifiers` 兜底，按普通文件交出，而不是直接丢弃。
- 视频和普通文件同样尝试文件/数据/旧 item 三种 representation，并在 completion 内立刻复制进 App Group，避免临时文件失效。
- `DispatchGroup` 等待全部附件，`NSLock` 保护共享数组，`completeRequest` / `cancelRequest` 只执行一次。
- 诊断日志写到 App Group 内 `Library/Logs/landrop-share.log`（上限 64 KB），免越狱可用文件管理器直接查看，现场失败可定位到具体是哪种表示、哪一步出错。
- JSON 继续是 `[{"value":..., "thumbnail":..., "duration":..., "type":Int}]`，`type` 严格保持 `text=0, url=1, image=2, video=3, file=4`；写入 `UserDefaults(suiteName:)` 的 `SharingKey`。
- 宿主 URL 仍是 `SharingMedia-app.landrop.landrop-flutter://dataUrl=SharingKey#media`（或 `#text/#url`），与已编译的 `flutter_sharing_intent` 和 Dart AOT 完全兼容。
- `main.m` 引用 Foundation 的 `NSExtensionMain`，链接器用 `-Wl,-e,_NSExtensionMain` 设置入口；纯 ObjC 避免 Swift ABI/兼容库问题。

## 签名与 entitlements（巨魔专用）

TrollStore 2.x 会：从每个 Mach-O 的 `LC_CODE_SIGNATURE` dump entitlements → 用 `ldid` 递归 ad-hoc 伪造签名 → 对所有 Mach-O 应用 CoreTrust bypass → 注册 App Group 容器与 PlugIns。它**不会**读取 bundle 里另放的 `entitlements.plist`，也不会展开 Xcode 变量 `$(AppIdentifierPrefix)`。完全不签名会导致 app 与 appex 拿不到共享 App Group。

因此构建脚本在打包前：

1. 用 `tools/prepare_entitlements.py` 生成两份**字面值** entitlements，保留原 Team ID、App Group、multicast 和 user-assigned-device-name；
2. `codesign --force --sign - --entitlements` 分别签 Runner 与 Share Extension；再签外层 `.app` 和嵌套 frameworks；
3. 不要 `get-task-allow`：iOS 16+ 的 TrollStore 遇到受限 entitlement 会要求开发者模式（错误 182）；
- 删除 `_CodeSignature`、`SC_Info`、`ITSDRMScheme`、`UISupportedDevices`，但**不修改** `MinimumOSVersion`（dyld 看 `LC_BUILD_VERSION`）。

产物是 ad-hoc 签名的 `LANDrop-2.8.2-fixed-trollstore.ipa`：没有开发者证书和 profile，TrollStore 安装时自行完成最终签名。Artifact 名称沿用 `fixed-trollstore`，文件名里不再写 `unsigned` 以免误解。

## GitHub Actions 编译验证

`.github/workflows/build-ios.yml` 只由 `workflow_dispatch` 手动触发，且必须从 **tag** 运行：工作流用 `github.ref_name` 作为版本标签，从该 tag 的**草稿 Release** 中读取解密 IPA asset（默认资产名 `LANDrop_2.8.2.ipa`）。

执行顺序是：代码先进入默认分支让 GitHub 注册工作流 → 创建并推送真实 Git tag → 用个人 Token 创建同 tag 的草稿 Release 并上传 IPA → 在 Actions 的 “Use workflow from” 选择该 tag 运行。工作流本身已在该 tag 的提交树中，checkout 为正常的 detached HEAD。

缓存键包含 tag、commit、补丁/脚本/工具源码哈希；重复运行同一个 tag 可复用已下载的 IPA 与 Xcode 工具缓存，避免每次从头下载/编译。工作流依次执行静态检查、从草稿 Release 下载并校验 IPA、macOS `clang` 编译、IPA 结构验证、上传 Artifact。草稿 Release 不会自动触发发布事件；没有 `push` 触发。

CI 的“通过”只代表静态结构、补丁字节、entitlements、无加密页等检查通过。蓝牙弹窗与系统截图分享仍需 TrollStore 真机验证。

## 真机验收

1. TrollStore 安装不出现 180；若出现 184，说明输入 decrypted IPA 中仍有其他加密嵌套二进制。
2. 关闭蓝牙后冷启动 LANDrop，不出现「打开蓝牙」系统提示；LAN 发现等原有功能正常。
3. 截图预览 → 分享 → LANDrop，应进入发送流程并自动选中该截图；相册图片/视频、Files 的 PNG/JPEG/HEIC 分享无回归。
4. 若宿主 App 打不开，先检查 App Group `group.app.landrop.landrop-flutter` 是否同时出现在 Runner 和 Share Extension 的签名 entitlements 中。
5. 若截图分享仍失败，App Group 内的 `Library/Logs/landrop-share.log` 记录了每个 provider 走了哪种表示、复制与图片规范化结果，以及宿主 URL 是否发出。

## 来源与边界

TrollStore 的 180/184、entitlements 保留、递归重签行为来自 opa334/TrollStore 2.x 源码（`RootHelper/main.m`、`TSApplicationsManager.m`、`Exploits/fastPathSign/src/coretrust_bug.c`）和 README；FairPlay 页写回机制来自 frida-ios-dump / TrollDecrypt / appdecrypt 源码。Flutter 主工程从未公开，AOT 中无法新增设置页开关，因此本版按用户允许的方案直接关闭弹窗，不声称是源码级修复，也不提供 DRM 解密或分发解密 IPA。
