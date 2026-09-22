#!/usr/bin/env python3
"""Build the app and sandboxed Finder extension with a pinned signature."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess
from signing import identity
from recovery_cache_key import write_cache_version

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--local-build', action='store_true',
                    help='Allow a non-Apple signing identity (unnotarized testing only).')
options = parser.parse_args()
signer = identity()
def run(*args):
    subprocess.run(args, cwd=root, check=True)

run('swift', 'build', '-c', 'release')
binary_dir = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
app = root / 'dist' / '轻压.app'
# A clean bundle cannot retain obsolete helpers from a previous release.
if app.exists():
    shutil.rmtree(app)
for name in ['MacOS', 'Resources', 'Helpers', 'Resources/Licenses']:
    (app / 'Contents' / name).mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Resources/Info.plist', app / 'Contents/Info.plist')
shutil.copy2(binary_dir / 'LightZip', app / 'Contents/MacOS/LightZip')
shutil.copy2(root / 'Vendor/7zip/7zz', app / 'Contents/Helpers/7zz')
shutil.copy2(root / 'Vendor/7zip/License.txt', app / 'Contents/Resources/Licenses/7-Zip.txt')
shutil.copy2(root / 'Vendor/7zip/LGPL-2.1.txt', app / 'Contents/Resources/Licenses/LGPL-2.1.txt')
shutil.copy2(root / 'Vendor/7zip-source.tar.xz', app / 'Contents/Resources/Licenses/7zip-source.tar.xz')
# Preserve the framework's versioned symlinks; sign nested code inside out.
sparkle_package = root / '.build/artifacts/sparkle/Sparkle'
sparkle = app / 'Contents/Frameworks/Sparkle.framework'
shutil.copytree(sparkle_package / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework', sparkle, symlinks=True)
shutil.copy2(sparkle_package / 'LICENSE', app / 'Contents/Resources/Licenses/Sparkle.txt')
for component in [sparkle / 'Versions/B/Autoupdate',
                  sparkle / 'Versions/B/Updater.app',
                  sparkle / 'Versions/B/XPCServices/Downloader.xpc',
                  sparkle / 'Versions/B/XPCServices/Installer.xpc', sparkle]:
    run('codesign', '--force', '--sign', signer, '--options', 'runtime',
        '--preserve-metadata=entitlements', str(component))
legacy_recovery = app / 'Contents/Helpers/Recovery'
if legacy_recovery.exists():
    shutil.rmtree(legacy_recovery)
recovery = app / 'Contents/Resources/Recovery'
if recovery.exists():
    shutil.rmtree(recovery)
shutil.copytree(root / 'Vendor/recovery', recovery, symlinks=True,
                ignore=shutil.ignore_patterns('Licenses', 'patches', '*source.tar.gz', 'README.md', 'man', 'perllocal.pod', '.packlist',
                    'kernels', '*.dictstat2*', '*.restore', '*.log', '*.potfile'))
shutil.copytree(root / 'Vendor/recovery/Licenses', app / 'Contents/Resources/Licenses/Recovery', dirs_exist_ok=True)
# GPL helper source is distributed alongside its independent executable.
shutil.copy2(root / 'Vendor/recovery/john-source.tar.gz', app / 'Contents/Resources/Licenses/Recovery/john-source.tar.gz')
shutil.copy2(root / 'Vendor/recovery/README.md', app / 'Contents/Resources/Licenses/Recovery/BUILD.md')
shutil.copytree(root / 'Vendor/recovery/patches', app / 'Contents/Resources/Licenses/Recovery/patches', dirs_exist_ok=True)
# Help is a native in-app page.
(app / 'Contents/Resources/使用说明.md').unlink(missing_ok=True)
shutil.copy2(root / 'THIRD_PARTY.md', app / 'Contents/Resources/Licenses/第三方说明.md')
shutil.copy2(root / 'LICENSE', app / 'Contents/Resources/Licenses/LightZip.txt')
for localization in (root / 'Resources').glob('*.lproj'):
    shutil.copytree(localization, app / 'Contents/Resources' / localization.name, dirs_exist_ok=True)
# Compile the Icon Composer document as a native, layered Liquid Glass icon.
# actool also emits the fallback .icns and the required bundle metadata.
icon_metadata = root / '.build/icon-info.plist'
run('xcrun', 'actool', str(root / 'Resources/AppIcon.icon'),
    '--compile', str(app / 'Contents/Resources'),
    '--output-format', 'human-readable-text', '--app-icon', 'AppIcon',
    '--platform', 'macosx', '--minimum-deployment-target', '26.0',
    '--target-device', 'mac', '--development-region', 'zh_CN',
    '--output-partial-info-plist', str(icon_metadata))
bundle_plist = app / 'Contents/Info.plist'
metadata = plistlib.loads(bundle_plist.read_bytes())
metadata.update(plistlib.loads(icon_metadata.read_bytes()))
bundle_plist.write_bytes(plistlib.dumps(metadata, sort_keys=False))
extension = app / 'Contents/PlugIns/LightZipFinder.appex'
(extension / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
extension_info = plistlib.loads((root / 'FinderExtension/Info.plist').read_bytes())
for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
    extension_info[key] = metadata[key]
(extension / 'Contents/Info.plist').write_bytes(plistlib.dumps(extension_info))
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
run('xcrun', 'swiftc', '-O', '-parse-as-library', '-emit-executable',
    '-module-name', 'LightZipFinder', '-application-extension', '-sdk', sdk,
    '-target', subprocess.check_output(['uname', '-m'], text=True).strip() + '-apple-macos26.0',
    '-framework', 'AppKit', '-framework', 'FinderSync',
    '-Xlinker', '-e', '-Xlinker', '_NSExtensionMain',
    str(root / 'Sources/FinderBridge/FinderRequest.swift'),
    str(root / 'FinderExtension/FinderSync.swift'),
    '-o', str(extension / 'Contents/MacOS/LightZipFinder'))
run('codesign', '--force', '--sign', signer, '--options', 'runtime',
    '--entitlements', str(root / 'FinderExtension/FinderExtension.entitlements'), str(extension))
run('codesign', '--force', '--sign', signer, '--options', 'runtime', str(app / 'Contents/Helpers/7zz'))
# Hashcat loads its own modules from the private working directory. These local
# command-line helpers are signed without the hardened library-validation flag.
for component in sorted(recovery.rglob('*')):
    if component.is_file() and not component.is_symlink():
        if component.read_bytes()[:4] in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf']:
            run('codesign', '--force', '--sign', signer, str(component))
write_cache_version(recovery / 'hashcat')
signature = subprocess.run(['codesign', '-dv', str(app / 'Contents/Helpers/7zz')],
                           capture_output=True, text=True, check=True).stderr
extra = []
if 'TeamIdentifier=not set' in signature:
    if not options.local_build:
        raise SystemExit('非 Apple 签名只能用于测试版；请显式添加 --local-build，或配置 Developer ID 身份。')
    # Local certificates have no Team ID, so macOS cannot match a framework to
    # its host. Scope this exception to the test app, never to system policy.
    entitlements = root / '.build/local-app.entitlements'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.cs.disable-library-validation': True}))
    extra = ['--entitlements', str(entitlements)]
    print('Unnotarized local build: app-scoped library validation exception enabled.')
run('codesign', '--force', '--sign', signer, '--options', 'runtime', *extra, str(app))
run('codesign', '--verify', '--deep', '--strict', str(app))
print(app)
