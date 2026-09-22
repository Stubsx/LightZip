# 发布轻压

## 一次性准备

维护者需要仓库写权限、GitHub CLI 登录、固定的代码签名证书，以及钥匙串中账号 `local.lightzip.app` 的 Sparkle Ed25519 私钥。不要把私钥写入仓库、脚本参数或日志。当前发布公钥在 `Resources/Info.plist` 的 `SUPublicEDKey`。

新 fork 应自行生成密钥、修改 bundle ID / Finder 扩展标识、`SUFeedURL` 和发布脚本中的仓库地址。不要为已有更新通道随意更换密钥。正式分发建议使用 Developer ID、Apple 公证及 stapling；本地签名构建必须标为未公证测试版。

## 准备发布

1. 修改 `Resources/Info.plist` 中的展示版本和递增的整数 build number。Finder 扩展版本由构建脚本同步。
2. 执行 `python3 scripts/bootstrap.py`、`swift test`，检查原生应用基本操作。改动密码引擎时另跑 GPU 集成测试。
3. 将发行说明写入 `docs/releases/版本.md`。
4. 提交源码，执行 `python3 scripts/release.py --local-build --notes docs/releases/版本.md`。使用 Developer ID 的正式版省略 `--local-build`，并在制作 ZIP 前完成公证和 stapling（可先独立构建、公证，再按脚本的打包/签名步骤执行）。

输出为 `dist/release-版本/`：安装 ZIP、`SHA256SUMS`、带签名的 `appcast.xml`。脚本使用 SwiftPM 下载的 Sparkle 工具，并验证签名公钥匹配、包签名和更新清单签名。它不会自行发布或导出私钥。已有产物目录不会覆盖；已发布的版本号和资产不得重新使用。

## 发布顺序

以下以 0.8.0 为例，后续替换为新版本：

```sh
git push origin main
gh release create v0.8.0 --draft --target main --title '轻压 0.8.0' \
  --notes-file docs/releases/0.8.0.md \
  dist/release-0.8.0/LightZip-0.8.0-arm64.zip \
  dist/release-0.8.0/SHA256SUMS \
  dist/release-0.8.0/appcast.xml
```

若运行时发生变化，先运行 `python3 scripts/package-runtime.py 0.8.0`，提交更新后的 `Vendor/runtime.json`，并给同一 Release 上传 `dist/LightZip-runtime-0.8.0-arm64.tar.gz`。首次发布也需要这个资产。普通 UI 更新继续复用原有运行时，无需重复上传。

确认版本、说明和资产后：

```sh
gh release edit v0.8.0 --draft=false --prerelease
cp dist/release-0.8.0/appcast.xml appcast.xml
git add appcast.xml
git commit -m 'Publish signed update feed for 0.8.0'
git push origin main
```

必须先让下载资产可用，再发布更新清单。生成后的 XML 不能手工改动，任何改动都需要重新签名。后续 `release.py` 会保留已有清单条目。

未公证测试版在 GitHub 标记为 Pre-release；达到正式发布标准后再使用普通 Release。

## 验证

- 从 GitHub 下载 ZIP，核对 SHA-256，并运行 `codesign --verify --deep --strict` 检查解压后的应用。
- 验证线上更新清单签名；确认版本、最低 macOS、Apple Silicon 要求、下载长度和 URL。
- `python3 scripts/verify-release.py Resources/Info.plist appcast.xml 下载的ZIP` 使用内置公钥和系统 CryptoKit 独立验证，不读取私钥或钥匙串。
- 在一个使用相同公钥、build number 较低的本地测试构建上，验证下载、安装、重启和最终版本。测试构建不发布到 GitHub。
- 更新过程中验证运行任务不会被强制终止；设置和访达右键状态应保留。

自动更新在 app 运行时检查，默认约 24 小时一次；下载完成后正常退出安装。手动检查使用 Sparkle 的标准确认和进度界面。应用关闭时不运行定时任务。
