import socketserver
import ssl
import sys
import time
from pathlib import Path

fixture = Path(sys.argv[1])
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(fixture / 'fullchain.pem', fixture / 'privkey.pem')
body = b'{"hung_up":true}'


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with tls.wrap_socket(self.request, server_side=True) as peer:
                request = b''
                while b'\r\n\r\n' not in request:
                    block = peer.recv(4096)
                    if not block:
                        return
                    request += block
                path = request.split(b' ', 2)[1]
                if path == b'/unframed':
                    peer.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n' + body[:5])
                    time.sleep(0.15)
                    peer.sendall(body[5:])
                    return
                if path in (b'/chunked', b'/chunked-incomplete'):
                    peer.sendall(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
                                 + f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n')
                    if path == b'/chunked-incomplete':
                        return
                    time.sleep(0.15)
                    peer.sendall(b'X-Complete: yes\r\n\r\n')
                elif path == b'/no-content':
                    peer.sendall(b'HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n')
                else:
                    size = len(body) + (100 if path == b'/truncated' else 0)
                    peer.sendall(f'HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: keep-alive\r\n\r\n'.encode())
                    peer.sendall(body[:5])
                    if path == b'/truncated':
                        return
                    if path == b'/fragmented':
                        time.sleep(0.15)
                    peer.sendall(body[5:])
                # Clients must finish on HTTP framing, without waiting for this TLS close.
                time.sleep(5)
        except (OSError, ssl.SSLError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(('127.0.0.1', 18446), Handler) as server:
    server.serve_forever()
