"""AirSIM UDP Opus experiment v1. Never send plaintext media over frp."""
import ctypes as C
import struct
import time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

MAGIC = b'AUO1'
HELLO, UP, DOWN, READY, PING, CLOSE = range(1, 7)
FRAME_SAMPLES, FRAME_BYTES = 160, 320  # 8 kHz mono, 20 ms

class Cipher:
    def __init__(self, psk, sid, sending_client):
        if len(psk) != 32 or len(sid) != 16:
            raise ValueError('32-byte key and 16-byte session required')
        self.sid, self.sequence = sid, 0
        def key(direction):
            return AESGCM(HKDF(algorithm=hashes.SHA256(), length=32,
                              salt=sid, info=b'AirSIM-UDP-v1/' + direction).derive(psk))
        self.tx = key(b'client' if sending_client else b'server')
        self.rx = key(b'server' if sending_client else b'client')
        self.highest, self.seen = -1, set()

    def seal(self, payload):
        if self.sequence >= 2**63: raise ValueError('session exhausted')
        seq = self.sequence
        self.sequence += 1
        header = MAGIC + self.sid + struct.pack('>Q', seq)
        return header + self.tx.encrypt(b'\0'*4 + struct.pack('>Q', seq), payload, header)

    def open(self, packet):
        if not 45 <= len(packet) <= 1200 or packet[:20] != MAGIC + self.sid:
            raise ValueError('invalid packet')
        seq, = struct.unpack('>Q', packet[20:28])
        if seq in self.seen or seq <= self.highest - 64:
            raise ValueError('replay')
        payload = self.rx.decrypt(b'\0'*4 + packet[20:28], packet[28:], packet[:28])
        self.highest = max(self.highest, seq)
        self.seen.add(seq)
        self.seen = {x for x in self.seen if x > self.highest - 64}
        return payload

class Jitter:
    """Bounded 60-120ms reorder buffer. Missing frames use Opus PLC/FEC."""
    def __init__(self):
        self.frames, self.next, self.start = {}, None, None
        self.delay = .06
        self.lost = self.late = self.dropped = 0

    def push(self, index, data, now=None):
        now = time.monotonic() if now is None else now
        if self.next is not None and index < self.next:
            self.late += 1
            return
        if self.start is None:
            self.next, self.start = index, now + self.delay
        if index > self.next + 50:  # catch up after a long stall; never replay old speech
            self.frames.clear()
            self.next, self.start = index, now + self.delay
            self.dropped += 1
        if index - self.next <= 15:
            self.frames.setdefault(index, data)

    def pop(self, now=None):
        now = time.monotonic() if now is None else now
        if self.start is None or now < self.start: return None
        index = self.next
        self.next += 1
        frame = self.frames.pop(index, None)
        if frame is None:
            self.lost += 1
        return frame, self.frames.get(index + 1)

class Opus:
    def __init__(self, path):
        self.lib = C.CDLL(str(path))
        lib = self.lib
        lib.opus_encoder_create.argtypes = [C.c_int, C.c_int, C.c_int, C.POINTER(C.c_int)]
        lib.opus_encoder_create.restype = C.c_void_p
        lib.opus_decoder_create.argtypes = [C.c_int, C.c_int, C.POINTER(C.c_int)]
        lib.opus_decoder_create.restype = C.c_void_p
        lib.opus_encode.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_void_p, C.c_int]
        lib.opus_decode.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_void_p, C.c_int, C.c_int]
        lib.opus_encoder_destroy.argtypes = [C.c_void_p]
        lib.opus_decoder_destroy.argtypes = [C.c_void_p]
        # ctl is variadic: explicitly type each argument below, including the pointer.
        error = C.c_int()
        self.encoder = lib.opus_encoder_create(8000, 1, 2048, C.byref(error))
        if not self.encoder or error.value: raise RuntimeError('Opus encoder unavailable')
        self.decoder = lib.opus_decoder_create(8000, 1, C.byref(error))
        if not self.decoder or error.value: self.close(); raise RuntimeError('Opus decoder unavailable')
        for request, value in [(4002, 12000), (4010, 5), (4012, 1), (4014, 10)]:
            if lib.opus_encoder_ctl(C.c_void_p(self.encoder), C.c_int(request), C.c_int(value)) < 0:
                self.close(); raise RuntimeError('Opus configuration failed')

    def encode(self, pcm):
        if len(pcm) != FRAME_BYTES: raise ValueError('one 20ms PCM frame required')
        output = C.create_string_buffer(400)
        count = self.lib.opus_encode(self.encoder, pcm, FRAME_SAMPLES, output, len(output))
        if count < 0: raise ValueError('Opus encode failed')
        return output.raw[:count]

    def decode(self, packet=None, fec=False):
        output = C.create_string_buffer(FRAME_BYTES)
        count = self.lib.opus_decode(self.decoder, packet, len(packet or b''), output,
                                     FRAME_SAMPLES, int(fec))
        if count != FRAME_SAMPLES: raise ValueError('invalid Opus frame')
        return output.raw

    def close(self):
        if getattr(self, 'encoder', None): self.lib.opus_encoder_destroy(self.encoder); self.encoder = None
        if getattr(self, 'decoder', None): self.lib.opus_decoder_destroy(self.decoder); self.decoder = None
