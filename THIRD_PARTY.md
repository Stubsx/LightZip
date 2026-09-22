# 第三方组件

## 7-Zip 26.03

- 作者：Igor Pavlov，Copyright (C) 1999–2026。
- 官方网站：https://www.7-zip.org/
- 未修改 macOS 引擎发布包：https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz
- 对应源码：https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz
- 许可证：GNU LGPL 2.1 或更新版本；部分代码为 BSD 及附 unRAR 限制。完整组件说明在 `Vendor/7zip/License.txt`，应用内同步附带。
- LGPL 完整条款：https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

引擎以独立可执行文件调用，位于应用的 `Contents/Helpers/7zz`。重新签名后可替换为兼容版本。完整对应源码随应用放在 `Contents/Resources/Licenses/7zip-source.tar.xz`，同时包含在版本化运行时下载包中。unRAR 代码不得用于重建专有 RAR 压缩算法。

## Sparkle 2.10.0

- 自动更新框架：https://github.com/sparkle-project/Sparkle
- 许可证：Sparkle 的宽松许可及其内含组件许可证，随应用附在 `Contents/Resources/Licenses/Sparkle.txt`。
- SwiftPM 固定版本和二进制校验和；发布包与更新清单使用 Ed25519 签名。

## 测试样本

RAR 样本来自 libarchive 官方仓库的 `libarchive/test`，只用于本地测试，不打包进应用。

- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar5_compressed.rar.uu
- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar.rar.uu
- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar_compress_normal.rar.uu
- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar_windows.rar.uu
- libarchive 授权：https://github.com/libarchive/libarchive/blob/master/COPYING ，仓库附 `Tests/LIBARCHIVE-LICENSE`。

## 密码找回组件（0.7.0）

- **Hashcat 7.1.2**：https://hashcat.net/hashcat/ ，MIT；附静态依赖的 LZMA SDK、zlib、xxHash、OpenCL headers、sse2neon、unRAR 等许可证。直接调用独立进程，随应用分发归档格式模块。轻压 0.7.3 增加可选的候选分批补丁：先分配小批候选，再逐步扩大；计算内核及自检保持上游实现。补丁源码及重建说明随应用分发。
- **John the Ripper bleeding-jumbo**：https://github.com/openwall/john ，GPL v2 或更新版本，含上游 OpenSSL/unRAR 例外。仅调用 zip2john / rar2john 转换器；完整对应源码 `john-source.tar.gz`、GPL 条款、构建说明随应用分发。
- **7z2hashcat 2.2**：https://github.com/philsmd/7z2hashcat ，public domain；原版脚本。
- **Compress::Raw::Lzma 2.219**：https://metacpan.org/dist/Compress-Raw-Lzma ，与 Perl 相同许可（GPL / Artistic）。
- **XZ liblzma 5.8.3**：https://tukaani.org/xz/ ，0BSD。动态库随应用打包，加载路径改为相对路径后重新签名。

各组件版本、源码 SHA-256、构建参数、运行限制及完整授权见 `Vendor/recovery/README.md`、`Vendor/recovery/Licenses`；安装包内位于 `Contents/Resources/Licenses/Recovery`。运行时组件位于 `Contents/Resources/Recovery`，无需 Homebrew。

加密 RAR 测试样本来自 libarchive，公开测试密码为 `password`：

- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar4_encrypted_filenames.rar.uu
- https://github.com/libarchive/libarchive/blob/master/libarchive/test/test_read_format_rar5_encrypted_filenames.rar.uu

这些测试样本不打包进应用。
