#!/usr/bin/env python3
"""Pin an existing local code-signing identity for stable Finder extension updates."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys

config_path = Path.home() / 'Library/Application Support/LightZip/Signing/identity.json'

def available(fingerprint):
    if not re.fullmatch(r'[A-F0-9]{40}', fingerprint):
        raise SystemExit('签名指纹必须为 40 位 SHA-1。')
    result = subprocess.check_output(['security', 'find-identity', '-p', 'codesigning'], text=True)
    if fingerprint not in result:
        raise SystemExit('固定的签名身份不可用，请解锁或恢复原钥匙串。')

def identity():
    override = os.environ.get('LIGHTZIP_SIGNING_IDENTITY')
    if override:
        available(override)
        return override
    if not config_path.is_file():
        raise SystemExit('请先用 python3 scripts/signing.py pin <SHA-1> 固定现有本机代码签名身份。')
    value = json.loads(config_path.read_text())['sha1']
    available(value)
    return value

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'pin':
        value = sys.argv[2].upper()
        available(value)
        if config_path.exists() and identity() != value:
            raise SystemExit('已有固定签名身份，不自动更换。')
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(json.dumps({'sha1': value}, indent=2) + '\n')
        print('已固定现有本机签名身份。')
    elif sys.argv[1:] == ['identity']:
        print(identity())
    else:
        raise SystemExit('用法：signing.py pin <SHA-1> | identity')
