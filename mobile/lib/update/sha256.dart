import 'dart:typed_data';

/// SHA-256 (FIPS 180-4) for checking a downloaded update, fed piece by piece while the file
/// arrives. Written here because the app has no hashing package of its own.
class Sha256 {
  static const _mask = 0xffffffff;

  static const _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final _h = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final _w = Uint32List(64);
  final _buffer = Uint8List(64);
  int _buffered = 0;
  int _length = 0;
  bool _closed = false;

  /// Hashes [data] in one go and returns the lowercase hex digest.
  static String hexOf(List<int> data) => (Sha256()..add(data)).closeHex();

  void add(List<int> data) {
    if (_closed) throw StateError('Sha256 is closed');
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _length += bytes.length;
    var i = 0;
    if (_buffered > 0) {
      while (_buffered < 64 && i < bytes.length) {
        _buffer[_buffered++] = bytes[i++];
      }
      if (_buffered < 64) return;
      _block(_buffer, 0);
      _buffered = 0;
    }
    while (bytes.length - i >= 64) {
      _block(bytes, i);
      i += 64;
    }
    while (i < bytes.length) {
      _buffer[_buffered++] = bytes[i++];
    }
  }

  /// Finishes the hash; the object cannot be used afterwards.
  Uint8List close() {
    if (_closed) throw StateError('Sha256 is closed');
    final bits = _length * 8;
    _buffer[_buffered++] = 0x80;
    if (_buffered > 56) {
      _buffer.fillRange(_buffered, 64, 0);
      _block(_buffer, 0);
      _buffered = 0;
    }
    _buffer.fillRange(_buffered, 56, 0);
    final hi = (bits >> 32) & _mask, lo = bits & _mask;
    for (var j = 0; j < 4; j++) {
      _buffer[56 + j] = (hi >> (24 - 8 * j)) & 0xff;
      _buffer[60 + j] = (lo >> (24 - 8 * j)) & 0xff;
    }
    _block(_buffer, 0);
    _closed = true;
    final out = Uint8List(32);
    for (var j = 0; j < 8; j++) {
      out[4 * j] = _h[j] >> 24;
      out[4 * j + 1] = (_h[j] >> 16) & 0xff;
      out[4 * j + 2] = (_h[j] >> 8) & 0xff;
      out[4 * j + 3] = _h[j] & 0xff;
    }
    return out;
  }

  String closeHex() => close().map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

  void _block(Uint8List d, int off) {
    final w = _w;
    for (var t = 0; t < 16; t++) {
      final o = off + 4 * t;
      w[t] = (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15], y = w[t - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[t] = w[t - 16] + s0 + w[t - 7] + s1; // Uint32List keeps the low 32 bits
    }
    var a = _h[0], b = _h[1], c = _h[2], e = _h[4], f = _h[5], g = _h[6];
    var dd = _h[3], h = _h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + _k[t] + w[t]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      h = g;
      g = f;
      f = e;
      e = (dd + t1) & _mask;
      dd = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += dd;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }
}
