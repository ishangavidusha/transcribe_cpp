import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/bindings.g.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

ModelDescriptor _custom(String id, {String family = 'parakeet'}) =>
    ModelDescriptor(
      id: ModelId(id),
      variant: id,
      quant: 'Q8_0',
      family: family,
      displayName: id,
      languages: const ['en'],
      license: 'apache-2.0',
      parameters: 1,
      sizeBytes: 1,
      sha256: '0' * 64,
      url: Uri.parse('https://example.com/$id.gguf'),
    );

void main() {
  final bundled = ModelCatalog.bundled();

  // The catalogue only loads if it was generated from the engine the
  // bindings came from. Regenerating one without the other fails here.
  test('bundled entries come from the linked engine release', () {
    expect(ModelCatalog.engineRelease, 'v$TRANSCRIBE_VERSION');
  });

  test('every bundled entry loads on the linked engine', () {
    expect(bundled.entries, isNotEmpty);
    expect(bundled.available, hasLength(bundled.entries.length));
  });

  test('every bundled entry is a pinned, verifiable single file', () {
    final hex64 = RegExp(r'^[0-9a-f]{64}$');
    final pinned = RegExp(
      r'^https://huggingface\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/[^/]+\.gguf$',
    );
    for (final e in bundled.entries) {
      expect(e.sha256, matches(hex64), reason: '${e.id}');
      // resolve/main would let a republished file break its own hash.
      expect(e.url.toString(), matches(pinned), reason: '${e.id}');
      expect(e.url.pathSegments.last, '${e.id.value}.gguf');
      expect(e.sizeBytes, inInclusiveRange(1, 1000000000), reason: '${e.id}');
    }
  });

  // The file every accuracy number in this package was measured with,
  // hashed locally from the copy downloaded on 2026-08-29.
  test('lists the measured parakeet file with its known hash', () {
    final e = bundled[const ModelId('parakeet-tdt_ctc-110m-Q4_K_M')]!;
    expect(e.variant, 'parakeet-tdt_ctc-110m');
    expect(e.quant, 'Q4_K_M');
    expect(e.family, 'parakeet');
    expect(e.sizeBytes, 89989600);
    expect(
      e.sha256,
      '486414fd90185a8c8a4ced7c123cfb133ff4f7958426c6b8bd9049946b56b448',
    );
  });

  test('an unknown id is null', () {
    expect(bundled[const ModelId('no-such-model')], isNull);
  });

  test('an app can offer its own models alongside the bundled ones', () {
    final mine = _custom('my-finetune');
    final catalog = bundled.withEntries([mine]);
    expect(catalog[mine.id], same(mine));
    expect(catalog.available, contains(mine));
    expect(catalog.entries.length, bundled.entries.length + 1);
  });

  test('a family the engine cannot load is listed but not available', () {
    final future = _custom('future', family: 'not_a_family');
    final catalog = ModelCatalog([future]);
    expect(catalog.entries, [future]);
    expect(catalog.available, isEmpty);
    expect(ModelCatalog.supportsFamily('parakeet'), isTrue);
    expect(ModelCatalog.supportsFamily('not_a_family'), isFalse);
  });

  test('a duplicate id is an error, not a silent override', () {
    expect(
      () => bundled.withEntries([_custom('parakeet-tdt_ctc-110m-Q4_K_M')]),
      throwsArgumentError,
    );
  });

  test('entries cannot be modified', () {
    expect(() => bundled.entries.clear(), throwsUnsupportedError);
  });
}
