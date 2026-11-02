#!/usr/bin/env python3
"""Package the complete Tracker Radar JSON losslessly with macOS libcompression."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Soulo/Source/Resources/trackerData.json'
MAGIC = b'SOULOTR1'
HEADER_SIZE = 48
MAX_DECODED_SIZE = 16 * 1024 * 1024
LZFSE = 0x801


def codec():
    library = ctypes.CDLL('/usr/lib/libcompression.dylib')
    for name in ['compression_encode_buffer', 'compression_decode_buffer']:
        function = getattr(library, name)
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_void_p, ctypes.c_uint]
        function.restype = ctypes.c_size_t
    return library


def decode(payload, library):
    if len(payload) <= HEADER_SIZE or payload[:8] != MAGIC:
        raise ValueError('Invalid tracker resource header')
    size = struct.unpack_from('<Q', payload, 8)[0]
    if not 0 < size <= MAX_DECODED_SIZE:
        raise ValueError('Invalid tracker resource decoded size')
    compressed = ctypes.create_string_buffer(payload[HEADER_SIZE:])
    result = ctypes.create_string_buffer(size)
    count = library.compression_decode_buffer(result, size, compressed,
        len(payload) - HEADER_SIZE, None, LZFSE)
    raw = result.raw
    if count != size or hashlib.sha256(raw).digest() != payload[16:HEADER_SIZE]:
        raise ValueError('Tracker resource is incomplete or has the wrong checksum')
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--check', action='store_true', help='Validate an existing output without writing')
    args = parser.parse_args()
    original = SOURCE.read_bytes()
    if not 0 < len(original) <= MAX_DECODED_SIZE:
        raise SystemExit('Tracker JSON exceeds the supported resource size')
    if not json.loads(original).get('trackers'):
        raise SystemExit('Tracker JSON must contain the complete nonempty tracker map')
    library = codec()
    if args.check:
        if decode(args.output.read_bytes(), library) != original:
            raise SystemExit('Compressed tracker resource does not match the source JSON')
        print('Tracker resource verified: all original bytes retained')
        return
    capacity = len(original) * 2 + 4096
    destination = ctypes.create_string_buffer(capacity)
    source = ctypes.create_string_buffer(original)
    count = library.compression_encode_buffer(destination, capacity, source, len(original), None, LZFSE)
    if count == 0:
        raise SystemExit('LZFSE compression failed')
    header = MAGIC + struct.pack('<Q', len(original)) + hashlib.sha256(original).digest()
    payload = header + destination.raw[:count]
    if decode(payload, library) != original:
        raise SystemExit('Lossless tracker round-trip verification failed')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_bytes() != payload:
        args.output.write_bytes(payload)
    # Old incremental app products can retain the previously copied JSON.
    # Remove that obsolete product file after verification, never the source.
    legacy = args.output.parent / SOURCE.name
    if args.output.parent.suffix == '.app' and legacy.resolve() != SOURCE.resolve() and legacy.is_file():
        legacy.unlink()
    print('Tracker resource: {} -> {} bytes ({} saved), byte-identical round trip'.format(
        len(original), len(payload), len(original) - len(payload)))


if __name__ == '__main__':
    main()
