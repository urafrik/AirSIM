"""Encrypted UDP/Opus <-> existing authenticated Android VoWLAN PCM gateway."""
import argparse
import asyncio
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import struct
import time
from protocol import Cipher, Jitter, Opus, DownlinkBuffer, MAGIC, HELLO, UP, DOWN, READY, PING, CLOSE

log = logging.getLogger('airsim-udp')

class Session:
    def __init__(self, gateway, address, cipher, hello):
        self.gateway, self.address, self.cipher = gateway, address, cipher
        self.hello, self.jitter = hello, Jitter()
        self.last_seen = time.monotonic()
        self.codec = None
        self.writer = None
        self.ready = False
        self.tx_index = self.uplink = self.downlink = self.catchups = 0
        self.capture_buffer = DownlinkBuffer()
        self.read_gap_ms_peak = 0
        self.task = asyncio.create_task(self.run())

    def send(self, payload):
        self.gateway.transport.sendto(self.cipher.seal(payload), self.address)

    def receive(self, payload):
        if not payload: return
        self.last_seen = time.monotonic()
        if payload[0] == HELLO and self.ready: self.send(bytes([READY]))
        elif payload[0] == UP and self.ready and 6 <= len(payload) <= 405:
            self.jitter.push(struct.unpack('>I', payload[1:5])[0], payload[5:])
        elif payload[0] == PING: self.send(bytes([PING]))
        elif payload[0] == CLOSE: self.task.cancel()

    async def run(self):
        try:
            self.codec = Opus(self.gateway.config['opus_library'])
            self.reader, self.writer = await asyncio.wait_for(asyncio.open_connection(
                self.gateway.config['android_host'], self.gateway.config.get('android_port', 7593)), 4)
            self.writer.get_extra_info('socket').setsockopt(__import__('socket').IPPROTO_TCP,
                                                          __import__('socket').TCP_NODELAY, 1)
            self.writer.write(self.hello)
            await self.writer.drain()
            if await asyncio.wait_for(self.reader.readexactly(11), 5) != b'AIRSIMREADY':
                raise ValueError('Android authentication failed')
            self.ready = True
            self.send(bytes([READY]))
            log.info('session_ready peer=%s', self.address)
            async with asyncio.TaskGroup() as group:
                group.create_task(self.capture())
                group.create_task(self.play())
                group.create_task(self.watchdog())
        except asyncio.CancelledError:
            pass
        except Exception as error:
            log.exception('session_closed reason=%s', type(error).__name__)
            try:
                self.send(b'\x07Android PCM session closed; see gateway.log')
            except Exception:
                pass
        finally:
            if self.writer: self.writer.close()
            if self.codec: self.codec.close()
            self.gateway.retired[self.cipher.sid] = time.monotonic()
            if self.gateway.session is self: self.gateway.session = None
            log.info('session_stats up=%d down=%d missing=%d late=%d up_clock_resets=%d rebuffers=%d down_queue_drops=%d down_stale_drops=%d down_queue_peak=%d read_gap_ms_peak=%d',
                     self.uplink, self.downlink, self.jitter.lost, self.jitter.late, self.catchups,
                     self.jitter.rebuffers, self.capture_buffer.overflow_drops,
                     self.capture_buffer.stale_drops, self.capture_buffer.peak,
                     self.read_gap_ms_peak)

    async def capture(self):
        # Android HAL can deliver ~96ms in a batch. Capacity must not mistake
        # that natural batching for a stalled network; stale audio is still bounded.
        async def read():
            last_read = time.monotonic()
            while True:
                pcm = await self.reader.readexactly(320)
                now = time.monotonic()
                self.read_gap_ms_peak = max(self.read_gap_ms_peak, round((now-last_read)*1000))
                last_read = now
                self.capture_buffer.push(self.tx_index, pcm)
                self.tx_index += 1
        async def send():
            deadline = time.monotonic()
            while True:
                index, pcm = await self.capture_buffer.get()
                self.send(bytes([DOWN]) + struct.pack('>I', index) + self.codec.encode(pcm))
                self.downlink += 1
                deadline += .02
                if deadline < time.monotonic() - .04: deadline = time.monotonic()
                await asyncio.sleep(max(0, deadline - time.monotonic()))
        async with asyncio.TaskGroup() as group:
            group.create_task(read())
            group.create_task(send())

    async def play(self):
        deadline = time.monotonic()
        while True:
            item = self.jitter.pop()
            if item is not None:
                packet, following = item
                pcm = self.codec.decode(packet if packet is not None else following,
                                        fec=packet is None and following is not None)
                self.writer.write(pcm)
                await asyncio.wait_for(self.writer.drain(), .25)
                self.uplink += 1
            deadline += .02
            if deadline < time.monotonic() - .04:
                # Do not burst old audio into Android after an event loop stall.
                deadline = time.monotonic()
                self.jitter.rebuffer()
                self.catchups += 1
            await asyncio.sleep(max(0, deadline - time.monotonic()))

    async def watchdog(self):
        while True:
            await asyncio.sleep(1)
            if time.monotonic() - self.last_seen > 8: raise TimeoutError('UDP idle')
            if int(time.monotonic()) % 5 == 0:
                log.info('media up=%d down=%d missing=%d late=%d up_clock_resets=%d rebuffers=%d buffer_ms=%d down_queue_drops=%d down_stale_drops=%d down_queue_peak=%d read_gap_ms_peak=%d',
                         self.uplink, self.downlink, self.jitter.lost, self.jitter.late, self.catchups,
                         self.jitter.rebuffers, round(self.jitter.delay*1000),
                         self.capture_buffer.overflow_drops, self.capture_buffer.stale_drops,
                         self.capture_buffer.peak, self.read_gap_ms_peak)

class Gateway(asyncio.DatagramProtocol):
    def __init__(self, config):
        self.config, self.session, self.retired = config, None, {}
        self.psk = bytes.fromhex(config['key_hex'])
        if len(self.psk) != 32: raise ValueError('key_hex must be 64 hex characters')
        if not ipaddress.ip_address(config['android_host']).is_private:
            raise ValueError('Android address must be private LAN IPv4')

    def connection_made(self, transport): self.transport = transport

    def datagram_received(self, data, address):
        if not 45 <= len(data) <= 1200 or data[:4] != MAGIC: return
        sid = data[4:20]
        try:
            if self.session:
                if sid != self.session.cipher.sid or address != self.session.address: return
                self.session.receive(self.session.cipher.open(data))
                return
            now = time.monotonic()
            self.retired = {k: v for k, v in self.retired.items() if now-v < 180}
            if sid in self.retired: return
            cipher = Cipher(self.psk, sid, False)
            payload = cipher.open(data)
            if not payload or payload[0] != HELLO: return
            hello = payload[1:]
            if not 80 <= len(hello) <= 256 or not hello.startswith(b'AIRSIMVWL1 ') or not hello.endswith(b'\n'): return
            # Android performs its existing timestamp/HMAC/replay checks before READY.
            self.session = Session(self, address, cipher, hello)
        except Exception:
            return  # Drop unauthenticated/malformed traffic without reflecting replies.

async def serve(config):
    loop = asyncio.get_running_loop()
    gateway = Gateway(config)
    transport, _ = await loop.create_datagram_endpoint(lambda: gateway,
        local_addr=(config.get('listen_host', '127.0.0.1'), config.get('listen_port', 17594)))
    log.info('listening UDP %s:%s; Android %s:%s', *transport.get_extra_info('sockname'),
             config['android_host'], config.get('android_port', 7593))
    try: await asyncio.Future()
    finally:
        if gateway.session:
            gateway.session.task.cancel()
            await asyncio.gather(gateway.session.task, return_exceptions=True)
        transport.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='gateway.local.json')
    parser.add_argument('--init', action='store_true')
    parser.add_argument('--android', default='192.168.1.88')
    args = parser.parse_args()
    path = Path(args.config)
    if args.init:
        config = {'android_host': args.android, 'android_port':7593,
                  'listen_host':'127.0.0.1', 'listen_port':17594,
                  'opus_library':'opus.dll',
                  'key_hex':os.urandom(32).hex()}
        with path.open('x', encoding='utf-8') as file: json.dump(config, file, indent=2)
        print('Created private configuration. Enter key_hex into iPhone; do not share this file.')
    else:
        file_handler = RotatingFileHandler(path.resolve().parent / 'gateway.log',
                                          maxBytes=2_000_000, backupCount=2, encoding='utf-8')
        logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s',
                            handlers=[logging.StreamHandler(), file_handler])
        config = json.loads(path.read_text(encoding='utf-8'))
        library = Path(config['opus_library'])
        if not library.is_absolute(): library = path.resolve().parent / library
        config['opus_library'] = str(library.resolve())
        asyncio.run(serve(config))
