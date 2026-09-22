"""Identify exactly the shipped Hashcat runtime for compiled-kernel caching."""
import hashlib
from pathlib import Path


def write_cache_version(runtime: Path) -> str:
    digest = hashlib.sha256()
    paths = [runtime / 'hashcat', runtime / 'hashcat.hcstat2']
    for name in ['OpenCL', 'modules', 'tunings']:
        paths.extend(p for p in (runtime / name).rglob('*') if p.is_file())
    for path in sorted(paths):
        digest.update(path.relative_to(runtime).as_posix().encode() + b'\0')
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
    version = digest.hexdigest()
    (runtime / 'cache-version').write_text(version + '\n')
    return version


if __name__ == '__main__':
    import sys
    print(write_cache_version(Path(sys.argv[1])))
