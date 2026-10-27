"""Exercise the shipped EXE against a synthetic Android PCM server (no phone calls)."""
import asyncio
import json
import math
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
from protocol import Cipher, Opus, HELLO, UP, DOWN

async def main(exe):
    async def android(reader, writer):
        try:
            await reader.readline()
            writer.write(b'AIRSIMREADY'); await writer.drain()
            while True:
                pcm = await reader.readexactly(320)
                writer.write(pcm); await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError): pass
        finally: writer.close()
    server = await asyncio.start_server(android, '127.0.0.1', 0)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    config = {'android_host':'127.0.0.1', 'android_port':server.sockets[0].getsockname()[1],
              'listen_host':'127.0.0.1', 'listen_port':port,
              'opus_library':os.environ.get('AIRSIM_OPUS_LIBRARY', str(exe.parent/'opus.dll')), 'key_hex':bytes(range(32)).hex()}
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder)/'gateway.local.json'
        path.write_text(json.dumps(config), encoding='utf-8')
        command = [sys.executable, str(exe)] if exe.suffix == '.py' else [str(exe)]
        process = subprocess.Popen(command + ['--config', str(path)], cwd=exe.parent,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        startup = await asyncio.wait_for(asyncio.to_thread(process.stdout.readline), 8)
        assert b"listening UDP" in startup, startup
        inbox = asyncio.Queue()
        class Client(asyncio.DatagramProtocol):
            def datagram_received(self, data, address):
                inbox.put_nowait(data)
        transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(Client,
            local_addr=('127.0.0.1', 0), remote_addr=('127.0.0.1', port))
        cipher = Cipher(bytes(range(32)), os.urandom(16), True)
        codec = Opus(config['opus_library'])
        try:
            for _ in range(20):
                transport.sendto(cipher.seal(bytes([HELLO])+b'AIRSIMVWL1 '+b'0'*90+b'\n'))
                try:
                    payload = cipher.open(await asyncio.wait_for(inbox.get(), .4))
                    if payload == bytes([4]): break
                except asyncio.TimeoutError: continue
            else: raise AssertionError('Frozen gateway never returned authenticated READY')
            for index in range(20):
                pcm = struct.pack('<160h', *[int(10000*math.sin((index*160+i)*2*math.pi*440/8000)) for i in range(160)])
                transport.sendto(cipher.seal(bytes([UP])+struct.pack('>I',index)+codec.encode(pcm)))
                await asyncio.sleep(.02)
            received = 0
            while received < 8:
                payload = cipher.open(await asyncio.wait_for(inbox.get(), 3))
                if payload[0] == DOWN:
                    assert len(codec.decode(payload[5:])) == 320
                    received += 1
            print('PASS: packaged Windows EXE, real encrypted UDP/Opus round trip, synthetic PCM endpoint.')
        finally:
            codec.close(); transport.close(); process.terminate()
            output = await asyncio.to_thread(process.communicate, timeout=5)
            print(output[0].decode(errors='replace'))
            server.close(); await server.wait_closed()

if __name__ == '__main__': asyncio.run(main(Path(sys.argv[1]).resolve()))
