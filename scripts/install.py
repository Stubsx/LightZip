#!/usr/bin/env python3
"""Install the app, register its Finder extension and keep services as a fallback."""
from pathlib import Path
from datetime import datetime
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
source = root / 'dist/轻压.app'
target = Path('/Applications/轻压.app')
desktop = Path.home() / 'Desktop/轻压.app'
backup = root / '.backups' / ('install-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
registration = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
extension_path = Path('Contents/PlugIns/LightZipFinder.appex')
extension_id = 'local.lightzip.app.finder'
was_enabled = subprocess.run(['pluginkit', '-m', '-i', extension_id], capture_output=True, text=True).stdout.lstrip().startswith('+')

if subprocess.run(['pgrep', '-x', 'LightZip'], capture_output=True).returncode == 0:
    raise SystemExit('请先退出轻压，再安装更新。')
for previous in [target, desktop]:
    if previous.exists():
        info = plistlib.loads((previous / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'local.lightzip.app':
            raise SystemExit(f'路径属于其他应用，未覆盖：{previous}')
staged = Path('/Applications/.轻压-install.app')
if staged.exists():
    raise SystemExit('安装暂存路径已存在，未覆盖。')
shutil.copytree(source, staged, symlinks=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
backup.mkdir(parents=True)
if target.exists():
    if (target / extension_path).exists():
        subprocess.run(['pluginkit', '-r', str(target / extension_path)], check=False)
    target.rename(backup / '应用程序-轻压.app')
try:
    staged.rename(target)
except Exception:
    if (backup / '应用程序-轻压.app').exists():
        (backup / '应用程序-轻压.app').rename(target)
    raise
if desktop.is_symlink():
    desktop.unlink()
elif desktop.exists():
    subprocess.run([registration, '-u', str(desktop)], check=False)
    desktop.rename(backup / '桌面-轻压.app')
desktop.symlink_to(target)
subprocess.run([registration, '-u', str(source)], check=False)
subprocess.run([registration, '-f', str(target)], check=True)
subprocess.run(['pluginkit', '-r', str(source / extension_path)], capture_output=True, check=False)
subprocess.run(['pluginkit', '-a', str(target / extension_path)], check=True)
if was_enabled:
    subprocess.run(['pluginkit', '-e', 'use', '-i', extension_id], check=True)
subprocess.run(['swift', 'scripts/register-services.swift'], cwd=root, check=True)
print(f'应用：{target}\n桌面入口：{desktop}\n旧版备份：{backup}')
