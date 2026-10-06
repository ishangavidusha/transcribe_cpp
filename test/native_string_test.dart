import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/native_string.dart';

/// A NUL-terminated copy of [bytes] in native memory, freed by [arena].
Pointer<Char> _native(Arena arena, List<int> bytes) {
  final p = arena<Uint8>(bytes.length + 1);
  for (var i = 0; i < bytes.length; i++) {
    p[i] = bytes[i];
  }
  p[bytes.length] = 0;
  return p.cast<Char>();
}

void main() {
  // "—" is E2 80 94. A byte-level tokenizer can put the first two bytes in one
  // token and the last in the next, which is how moonshine lost a whole
  // utterance on a real conversation: the strict decode threw.
  const dashHead = [0xE2, 0x80];
  const dashTail = [0x94];

  test('a token holding part of a character decodes instead of throwing', () {
    using((arena) {
      final head = _native(arena, dashHead);
      expect(
        () => head.cast<Utf8>().toDartString(),
        throwsFormatException,
        reason: 'the strict decode this replaces',
      );
      expect(decodeNativeText(head), '�');
      expect(decodeNativeText(_native(arena, dashTail)), '�');
    });
  });

  test('well-formed text is unchanged', () {
    using((arena) {
      const text = 'naïve — 22.7% 🎙';
      final p = text.toNativeUtf8(allocator: arena).cast<Char>();
      expect(decodeNativeText(p), text);
    });
  });

  test('an explicit length reads exactly that many bytes', () {
    using((arena) {
      // The streaming API hands over a byte count, and a count that ends
      // mid-character is the same split seen from the other side.
      final p = _native(arena, [0x61, ...dashHead, ...dashTail]);
      expect(decodeNativeText(p, length: 3), 'a�');
      expect(decodeNativeText(p, length: 4), 'a—');
    });
  });

  test('null is empty', () {
    expect(decodeNativeText(nullptr), '');
  });
}
