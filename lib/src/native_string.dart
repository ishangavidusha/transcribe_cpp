import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Decodes engine text, replacing malformed UTF-8 with U+FFFD instead of
/// throwing.
///
/// Byte-level tokenizers split a multi-byte character across tokens, so a
/// single token's text can end mid-character. A strict decode throws a
/// `FormatException` there, and the exception takes the whole transcript with
/// it: moonshine lost an utterance this way on a real conversation.
///
/// [length] is the byte count when the engine gives one; otherwise the string
/// is read up to its NUL terminator.
String decodeNativeText(Pointer<Char> p, {int? length}) {
  if (p == nullptr) return '';
  final utf8Pointer = p.cast<Utf8>();
  final n = length ?? utf8Pointer.length;
  return utf8.decode(p.cast<Uint8>().asTypedList(n), allowMalformed: true);
}
