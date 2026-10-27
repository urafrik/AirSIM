import asyncio
import math
import os
from pathlib import Path
import struct
import unittest
from gateway import Gateway
from protocol import Cipher, Jitter, Opus, HELLO, UP, DOWN, READY

LIBRARY = Path(os.environ.get('AIRSIM_OPUS_LIBRARY', Path(__file__).parent / 'opus.dll')).resolve()

class ProtocolTests(unittest.TestCase):
    def test_auth_direction_tampering_replay_and_reordering(self):
        key, sid = bytes(range(32)), bytes(range(16))
        client, server = Cipher(key, sid, True), Cipher(key, sid, False)
        packets = [client.seal(bytes([i])) for i in range(3)]
        bad = packets[0][:-1] + bytes([packets[0][-1] ^ 1])
        with self.assertRaises(Exception): server.open(bad)
        self.assertEqual(server.open(packets[1]), b'\1')
        self.assertEqual(server.open(packets[0]), b'\0')
        with self.assertRaises(ValueError): server.open(packets[0])
        with self.assertRaises(Exception): client.open(packets[2])
        self.assertEqual(client.open(server.seal(b'ack')), b'ack')
        other = Cipher(key, os.urandom(16), False)
        with self.assertRaises(ValueError): other.open(packets[2])

    def test_jitter_late_loss_reordering_and_bounded_stall(self):
        jitter = Jitter()
        jitter.push(0, b'a', now=0)
        jitter.push(2, b'c', now=.01)
        self.assertIsNone(jitter.pop(now=.02))
        self.assertEqual(jitter.pop(now=.06), (b'a', None))
        self.assertEqual(jitter.pop(now=.08), (None, b'c'))
        jitter.push(1, b'late', now=.09)
        self.assertEqual(jitter.late, 1)
        self.assertEqual(jitter.pop(now=.10), (b'c', None))
        jitter.push(500, b'new', now=10)
        self.assertEqual(jitter.next, 500)
        self.assertLessEqual(len(jitter.frames), 16)

    def test_real_opus_encode_decode_and_loss_concealment(self):
        codec = Opus(LIBRARY)
        try:
            pcm = struct.pack('<160h', *[int(12000*math.sin(i*2*math.pi*440/8000)) for i in range(160)])
            packets = [codec.encode(pcm) for _ in range(10)]
            self.assertTrue(all(0 < len(p) < 100 for p in packets))
            decoded = [codec.decode(p) for p in packets]
            self.assertTrue(any(any(p) for p in decoded))
            self.assertEqual(len(codec.decode()), 320)
            self.assertEqual(len(codec.decode(packets[-1], fec=True)), 320)
        finally: codec.close()

    def test_sustained_late_stream_reanchors_instead_of_permanent_plc(self):
        jitter = Jitter()
        jitter.push(0, b'a', now=0)
        for tick in range(20): jitter.pop(now=.061 + tick*.02)
        # First preview kept advancing forever here, rejecting every arriving frame.
        decoded = 0
        for index in range(1, 101):
            now = .50 + index*.02
            jitter.push(index, b'voice', now=now)
            item = jitter.pop(now=now)
            if item and item[0] is not None: decoded += 1
        self.assertGreater(decoded, 80)
        self.assertLessEqual(jitter.delay, .12)
        self.assertLess(jitter.rebuffers, 5)

    def test_late_but_ordered_sender_recovers_when_playout_ahead(self):
        jitter = Jitter()
        jitter.push(0, b'first', now=0)
        jitter.next, jitter.start = 100, 0  # Model the actual ahead-of-stream state.
        for index in range(1, 4): jitter.push(index, b'voice', now=.1 + index*.02)
        self.assertEqual(jitter.next, 3)
        self.assertGreaterEqual(jitter.rebuffers, 1)

class IntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_encrypted_udp_to_authenticated_pcm_and_back(self):
        connections = []
        async def android(reader, writer):
            connections.append(1)
            try:
                self.assertTrue((await reader.readline()).startswith(b'AIRSIMVWL1 '))
                writer.write(b'AIRSIMREADY'); await writer.drain()
                while True:
                    pcm = await reader.readexactly(320)
                    writer.write(pcm); await writer.drain()
            except asyncio.IncompleteReadError: pass
            finally: writer.close()
        server = await asyncio.start_server(android, '127.0.0.1', 0)
        key, sid = bytes(range(32)), os.urandom(16)
        gateway = Gateway({'key_hex':key.hex(), 'opus_library':str(LIBRARY),
                           'android_host':'127.0.0.1', 'android_port':server.sockets[0].getsockname()[1]})
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(lambda: gateway, local_addr=('127.0.0.1', 0))
        inbox = asyncio.Queue()
        class Client(asyncio.DatagramProtocol):
            def datagram_received(self, data, address): inbox.put_nowait(data)
        client, _ = await loop.create_datagram_endpoint(Client, remote_addr=transport.get_extra_info('sockname'))
        cipher, codec = Cipher(key, sid, True), Opus(LIBRARY)
        try:
            hello = bytes([HELLO]) + b'AIRSIMVWL1 ' + b'0'*90 + b'\n'
            client.sendto(cipher.seal(hello))
            self.assertEqual(cipher.open(await asyncio.wait_for(inbox.get(), 3)), bytes([READY]))
            for index in range(15):
                pcm = struct.pack('<160h', *[int(9000*math.sin((index*160+i)*2*math.pi*440/8000)) for i in range(160)])
                packet = cipher.seal(bytes([UP]) + struct.pack('>I', index) + codec.encode(pcm))
                if index != 4: client.sendto(packet)  # One deliberate lost 20ms frame.
                await asyncio.sleep(.02)
            received = []
            while len(received) < 8:
                payload = cipher.open(await asyncio.wait_for(inbox.get(), 3))
                if payload[0] == DOWN:
                    received.append(codec.decode(payload[5:]))
            self.assertTrue(any(any(frame) for frame in received))
            self.assertEqual(len(connections), 1)
            self.assertGreaterEqual(gateway.session.jitter.lost, 1)
            # A replay or wrong key must not take over the established session.
            client.sendto(packet)
            client.sendto(Cipher(os.urandom(32), sid, True).seal(hello))
            await asyncio.sleep(.02)
            self.assertEqual(len(connections), 1)
        finally:
            if gateway.session:
                gateway.session.task.cancel()
                await asyncio.gather(gateway.session.task, return_exceptions=True)
            codec.close(); client.close(); transport.close(); server.close()
            await server.wait_closed()

if __name__ == '__main__': unittest.main(verbosity=2)
