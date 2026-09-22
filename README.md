# 轻压 · LightZip

一个原生 macOS 26 压缩工具。打开压缩包后直接浏览文件夹，按空格预览，双击打开文件；只在需要时解压相应文件。

[下载最新版本](https://github.com/Stubsx/LightZip/releases/latest) · [提交问题](https://github.com/Stubsx/LightZip/issues)

## 功能

- 浏览和解压 ZIP、7Z、RAR、TAR、GZ、BZ2、XZ 等常见格式；创建 ZIP、7Z。
- 按需解压、空格 Quick Look、双击调用默认应用；退出时清理临时文件。固实压缩包读取后部文件仍可能需要解码前面的数据。
- 访达右键压缩、解压；可在设置中管理扩展并设为默认打开应用。
- 找回自己压缩包的简单密码：数字、字母数字、符号组合，或字典和规则；支持设备可用的 GPU 后端。
- 内置使用说明与设置；Icon Composer 分层图标。
- Sparkle 自动更新：运行时约每 24 小时检查，后台下载并验签，正常退出时替换应用。菜单和设置中可手动检查更新。

## 安装

需要 **Apple Silicon（M 系列）和 macOS 26 或更新版本**。当前发布包不支持 Intel Mac。

1. 从 Releases 下载 `LightZip-版本号-arm64.zip`。
2. 解压，将 `轻压.app` 放进“应用程序”后打开。
3. 如需访达右键，在轻压“设置 → 启用右键菜单”中打开系统扩展开关。

**0.8.0 是未公证测试版**，使用本地代码签名，尚无 Apple Developer ID 公证。macOS 可能阻止首次打开；确认下载来源后可按系统“隐私与安全性”页面的提示处理。无需关闭 Gatekeeper 或 SIP。更新清单及安装包均使用 Ed25519 签名验证；这与 Apple 公证是不同的验证。

自动更新只在应用运行时检查，不安装常驻后台服务。关闭“自动下载并安装更新”后仍可手动检查。下载完成的更新在正常退出时安装，不会强行中断压缩或解压；临时工作区按原有退出流程清理。

## 从源码构建

需要 Apple Silicon Mac、macOS 26、完整 Xcode 26 或更新版本（提供 Swift 及 `actool`）、Python 3.12+。发布用第三方运行时已固定版本和 SHA-256，无需安装 Homebrew 运行依赖。

```sh
git clone https://github.com/Stubsx/LightZip.git
cd LightZip
python3 scripts/bootstrap.py
swift test
```

配置本机已有的代码签名身份（不能使用其他人的证书或密钥）：

```sh
security find-identity -p codesigning
python3 scripts/signing.py pin YOUR_40_CHARACTER_CERTIFICATE_SHA1
python3 scripts/build.py --local-build
```

产物为 `dist/轻压.app`。`--local-build` 用于本地证书测试：仅对轻压本身设置动态库加载兼容权限，保留 Hardened Runtime；不会修改系统安全策略。有 Apple Developer ID 身份时省略此选项，构建不会添加该权限。也可通过 `LIGHTZIP_SIGNING_IDENTITY` 指定证书指纹。

可将应用手动复制到“应用程序”，或先退出轻压再运行 `python3 scripts/install.py`。安装脚本会备份旧版、保留访达扩展的启用状态，并创建桌面入口。

常规测试默认跳过 GPU 集成测试。测试 GPU 找回功能时：

```sh
LIGHTZIP_RECOVERY_INTEGRATION=1 swift test --filter PasswordRecoveryTests
```

## 发布与更新

发布说明见 [docs/RELEASING.md](docs/RELEASING.md)。发布包和更新清单都必须使用与应用内公钥对应的 Sparkle 私钥签名；私钥存于维护者的 macOS 钥匙串，仓库不包含私钥。

Fork 项目时请修改应用标识、更新源和公钥；不要把自己的构建发布到原项目的更新通道。第三方运行时的来源、构建参数和许可证见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [Vendor/recovery/README.md](Vendor/recovery/README.md)。

## 许可

轻压原创代码及图标采用 [MIT](LICENSE) 许可。7-Zip、Hashcat、John、Sparkle 和其他第三方组件各自保留原许可证。GPL/LGPL 对应源码随运行时与应用包一起提供。RAR 仅解压，不提供 RAR 压缩。
