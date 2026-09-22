#!/usr/bin/env python3
"""Package reviewed third-party runtime and sources, and pin its release asset."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import tarfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('version')
args = parser.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
    parser.error('Use a numeric release version, e.g. 0.8.0')
name = f'LightZip-runtime-{args.version}-arm64.tar.gz'
output = root / 'dist' / name
output.parent.mkdir(exist_ok=True)

def reviewed(info):
    parts = Path(info.name).parts
    if any(p in {'.DS_Store', '__pycache__', 'kernels', '.git', '.packlist', 'perllocal.pod', 'man'} for p in parts):
        return None
    if info.name.endswith(('.log', '.potfile', '.restore', '.dictstat2')):
        return None
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    return info

with tarfile.open(output, 'w:gz') as archive:
    for item in ['7zip', '7zip-source.tar.xz', 'recovery']:
        archive.add(root / 'Vendor' / item, arcname=item, filter=reviewed)
manifest = {
    'architecture': 'arm64',
    'url': f'https://github.com/Stubsx/LightZip/releases/download/v{args.version}/{name}',
    'sha256': hashlib.file_digest(output.open('rb'), 'sha256').hexdigest(),
    'size': output.stat().st_size
}
(root / 'Vendor/runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(output)
