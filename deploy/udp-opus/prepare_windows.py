"""Download only the hash-pinned Opus DLL and its license, never credentials."""
from pathlib import Path
import hashlib
import io
import tarfile
import urllib.request

URL = 'https://conda.anaconda.org/conda-forge/win-64/libopus-1.3.1-h8ffe710_1.tar.bz2'
SHA = 'b2e5ec193762a5b4f905f8100437370e164df3db0ea5c18b4ce09390f5d3d525'
def prepare(directory):
    data = urllib.request.urlopen(URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SHA: raise ValueError('Opus download hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:bz2') as tar:
        for source, target in [('Library/bin/opus.dll', 'opus.dll'), ('info/licenses/COPYING', 'Opus-LICENSE.txt')]:
            (directory / target).write_bytes(tar.extractfile(source).read())
    print('Verified Opus DLL and license prepared.')
if __name__ == '__main__': prepare(Path(__file__).resolve().parent)
