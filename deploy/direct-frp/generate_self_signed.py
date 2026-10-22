#!/usr/bin/env python3
"""Generate a private server key and a self-signed certificate locally, never in CI."""
import argparse
import hashlib
import ipaddress
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True, help='Same DNS host or IPv4 used by the iPhone')
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
host = args.host.strip().lower()
try:
    ip = ipaddress.IPv4Address(host)
    san = 'IP:' + str(ip)
except ipaddress.AddressValueError:
    if len(host) > 253 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', host):
        parser.error('Invalid DNS host or IPv4')
    san = 'DNS:' + host
openssl = shutil.which('openssl')
if not openssl:
    parser.error('Install OpenSSL first and add it to PATH')
args.out.mkdir(parents=True, exist_ok=True)
cert, key = args.out / 'fullchain.pem', args.out / 'privkey.pem'
if cert.exists() or key.exists():
    parser.error('Refusing to overwrite an existing certificate or private key; use a new directory')
with tempfile.TemporaryDirectory(prefix='airsim-cert-config-') as temporary:
    config = Path(temporary) / 'openssl.cnf'
    config.write_text('[req]\ndistinguished_name = req_dn\n[req_dn]\n', encoding='ascii')
    result = subprocess.run([
    openssl, 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '365', '-nodes',
    '-keyout', str(key), '-out', str(cert), '-subj', '/CN=' + host,
    '-addext', 'subjectAltName=' + san,
    '-addext', 'basicConstraints=critical,CA:FALSE',
    '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
    '-addext', 'extendedKeyUsage=serverAuth', '-config', str(config),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode:
        raise SystemExit('OpenSSL failed: ' + result.stderr.decode(errors='replace'))
try:
    key.chmod(0o600)
except OSError:
    pass
fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
(args.out / 'certificate-sha256.txt').write_text(fingerprint + '\n', encoding='ascii')
print('Certificate host:', host)
print('Certificate SHA256:', fingerprint)
print('Private key is local only:', key)
