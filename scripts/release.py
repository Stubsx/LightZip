#!/usr/bin/env python3
"""Prepare a signed release ZIP, appcast and SHA256SUMS. Does not publish."""
from pathlib import Path
import argparse
import hashlib
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--local-build', action='store_true', help='Unnotarized testing only')
parser.add_argument('--notes', type=Path, required=True, help='Release notes in Markdown')
args = parser.parse_args()
notes = args.notes.resolve().read_text()
subprocess.run([sys.executable, str(root / 'scripts/build.py'), *(['--local-build'] if args.local_build else [])], check=True)
app = root / 'dist/轻压.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
directory = root / 'dist' / f'release-{version}'
if directory.exists():
    raise SystemExit(f'Release directory already exists: {directory}. Do not overwrite published assets.')
directory.mkdir()
archive = directory / f'LightZip-{version}-arm64.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
archive.with_suffix('.md').write_text(notes)
tools = root / '.build/artifacts/sparkle/Sparkle/bin'
account = info['CFBundleIdentifier']
# Signing must use the private key corresponding to the public key in the app.
public = subprocess.check_output([str(tools / 'generate_keys'), '--account', account, '-p'], text=True).strip()
if public != info['SUPublicEDKey']:
    raise SystemExit('Signing key does not match SUPublicEDKey. No feed published.')
feed = directory / 'appcast.xml'
if (root / 'appcast.xml').exists():
    shutil.copyfile(root / 'appcast.xml', feed)
subprocess.run([str(tools / 'generate_appcast'), '--account', account, '--maximum-deltas', '0',
                '--download-url-prefix', f'https://github.com/Stubsx/LightZip/releases/download/v{version}/',
                '--embed-release-notes', str(directory)], check=True)
subprocess.run([sys.executable, str(root / 'scripts/verify-release.py'),
                str(app / 'Contents/Info.plist'), str(feed), str(archive)], check=True)
with archive.open('rb') as file:
    digest = hashlib.file_digest(file, 'sha256').hexdigest()
(directory / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
print(f'Ready: {directory}\nUpload release assets first, then publish this exact signed appcast.xml.')
