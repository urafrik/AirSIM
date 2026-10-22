#!/usr/bin/env python3
"""Package a physical-device Xcode .app as an unsigned IPA; no signing secrets."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def inspect_bundle(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = info.get('CFBundleExecutable')
    if not executable or not (app / executable).is_file():
        raise ValueError(f'Missing executable: {app.name}')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('IPA must contain a physical iPhoneOS build, not a simulator build')
    if not any((app / 'Watch').glob('*.app')):
        raise ValueError('Watch companion app was not embedded')
    if not any((app / 'PlugIns').glob('*.appex')):
        raise ValueError('Live Activity extension was not embedded')
    return info


def main():
    source, output = (Path(p).resolve() for p in sys.argv[1:])
    info = inspect_bundle(source)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='airsim-unsigned-') as scratch:
        payload = Path(scratch) / 'Payload'
        payload.mkdir()
        app = payload / 'AirSIM.app'
        subprocess.run(['ditto', str(source), str(app)], check=True)
        # Archive was built with signing disabled. Do not retain any copied profiles.
        for path in list(app.rglob('embedded.mobileprovision')):
            path.unlink()
        for path in list(app.rglob('_CodeSignature')):
            if path.is_dir():
                shutil.rmtree(path)
        if any(app.rglob('embedded.mobileprovision')) or any(app.rglob('_CodeSignature')):
            raise ValueError('Unexpected signing material remains in staged payload')
        version = str(info.get('CFBundleShortVersionString', 'dev'))
        if not version or any(c not in '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-' for c in version):
            raise ValueError('Invalid version for artifact filename')
        ipa = output / f'AirSIM-iOS-{version}-frp-unsigned.ipa'
        subprocess.run(['ditto', '-c', '-k', '--keepParent', '--norsrc', str(payload), str(ipa)], check=True)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (output / 'SHA256SUMS.txt').write_text(f'{digest}  {ipa.name}\n', encoding='utf-8')
    (output / 'build-info.json').write_text(json.dumps({
        'bundle_id': info['CFBundleIdentifier'],
        'version': info.get('CFBundleShortVersionString'),
        'build': info.get('CFBundleVersion'),
        'signed': False,
        'contains_watch_app': True,
        'contains_live_activity': True,
    }, indent=2) + '\n', encoding='utf-8')
    print(ipa)


if __name__ == '__main__':
    main()
