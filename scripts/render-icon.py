#!/usr/bin/env python3
"""Render Icon Composer previews with Apple's macOS 26 Liquid Glass effects."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
tool = developer.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
if not tool.is_file():
    raise SystemExit('需要包含 Icon Composer 的完整 Xcode。')
destination = root / 'Design/Previews'
destination.mkdir(parents=True, exist_ok=True)
for rendition, size, filename in [
    ('Default', 1024, 'Default'), ('Default', 512, 'Preview'),
    ('Dark', 512, 'Dark'), ('TintedLight', 512, 'Tinted'),
    ('Default', 128, 'Spotlight'), ('Default', 64, 'Dock'),
    ('Default', 32, 'Small'), ('Dark', 32, 'DarkSmall'), ('Default', 16, 'List'),
]:
    subprocess.run([
        str(tool), str(root / 'Resources/AppIcon.icon'), '--export-image',
        '--output-file', str(destination / (filename + '.png')),
        '--platform', 'macOS', '--rendition', rendition,
        '--width', str(size), '--height', str(size), '--scale', '1',
        '--design-generation', '26',
    ], check=True, capture_output=True)
print(f'已导出 macOS 26 图标预览：{destination}')
