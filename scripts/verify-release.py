#!/usr/bin/env python3
"""Verify a Sparkle feed and archive with the app's public key only."""
from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('info', type=Path)
parser.add_argument('feed', type=Path)
parser.add_argument('archive', type=Path)
args = parser.parse_args()
info = plistlib.loads(args.info.read_bytes())
data = args.feed.read_bytes()
# Sparkle 2.10's signed feed format: content followed by a signature comment.
content, separator, block = data.rpartition(b'<!-- sparkle-signatures:\n')
if not separator or not block.endswith(b'-->\n'):
    raise SystemExit('Missing signed feed block')
attributes = dict(line.split(':', 1) for line in block[:-4].decode().splitlines() if ':' in line)
if len(content) != int(attributes.get('length', '-1')):
    raise SystemExit('Feed length mismatch')

def verify(path, signature):
    subprocess.run(['swift', str(root / 'scripts/verify-signature.swift'),
                    info['SUPublicEDKey'], signature.strip(), str(path)], check=True)

with tempfile.TemporaryDirectory(prefix='lightzip-feed-') as directory:
    signed_content = Path(directory) / 'feed-content'
    signed_content.write_bytes(content)
    verify(signed_content, attributes['edSignature'])
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.fromstring(content).findall('./channel/item')
matches = [item for item in items if item.findtext(ns + 'version') == info['CFBundleVersion']]
if len(matches) != 1:
    raise SystemExit('Expected exactly one feed item for the app build')
enclosure = matches[0].find('enclosure')
if enclosure is None or int(enclosure.get('length', '-1')) != args.archive.stat().st_size:
    raise SystemExit('Archive length mismatch')
url = urllib.parse.urlsplit(enclosure.attrib['url'])
if url.scheme != 'https' or Path(urllib.parse.unquote(url.path)).name != args.archive.name:
    raise SystemExit('Unexpected archive URL')
verify(args.archive, enclosure.attrib[ns + 'edSignature'])
print('Feed and archive signatures verified using the embedded public key.')
