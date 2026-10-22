"""Loopback-only TLS fixture for macOS CI; uses disposable test keys in RUNNER_TEMP."""
from pathlib import Path
import socket
import ssl
import sys

root = Path(sys.argv[1])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(root / 'fullchain.pem', root / 'privkey.pem')
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    (root / 'port.txt').write_text(str(listener.getsockname()[1]))
    while True:
        peer, _ = listener.accept()
        try:
            with context.wrap_socket(peer, server_side=True) as secure:
                secure.settimeout(3)
                secure.recv(16)
        except (ssl.SSLError, OSError):
            peer.close()
