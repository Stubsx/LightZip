#!/usr/bin/env python3
"""Fetch the pinned runtime. Requires Python 3.12+ for safe tar extraction."""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import shutil
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=Path, help='Verify a previously downloaded asset instead')
args = parser.parse_args()
manifest = json.loads((root / 'Vendor/runtime.json').read_text())
if platform.system() != 'Darwin' or platform.machine() != manifest['architecture']:
    raise SystemExit('The bundled runtime requires Apple Silicon macOS; see Vendor/recovery/README.md to rebuild.')
if not hasattr(tarfile, 'data_filter'):
    raise SystemExit('Python 3.12 or newer is required.')
with tempfile.TemporaryDirectory(prefix='lightzip-runtime-') as directory:
    stage = Path(directory)
    archive = stage / 'runtime.tar.gz'
    if args.archive:
        shutil.copyfile(args.archive, archive)
    else:
        print('Downloading pinned runtime…', flush=True)
        with urllib.request.urlopen(manifest['url'], timeout=120) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    with archive.open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest()
    if digest != manifest['sha256'] or archive.stat().st_size != manifest['size']:
        raise SystemExit('Runtime checksum mismatch; nothing installed.')
    with tarfile.open(archive) as package:
        package.extractall(stage / 'unpacked', filter='data')
    unpacked = stage / 'unpacked'
    for item in ['7zip', 'recovery']:
        # copytree cannot replace existing symlinks on a repeated bootstrap.
        for link in (unpacked / item).rglob('*'):
            if link.is_symlink():
                destination = root / 'Vendor' / link.relative_to(unpacked)
                if destination.is_symlink():
                    destination.unlink()
        shutil.copytree(unpacked / item, root / 'Vendor' / item, symlinks=True, dirs_exist_ok=True)
    shutil.copy2(unpacked / '7zip-source.tar.xz', root / 'Vendor/7zip-source.tar.xz')
print('Runtime verified and ready.')
