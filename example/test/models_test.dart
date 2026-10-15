import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';
import 'package:transcribe_cpp_example/models.dart';

void main() {
  final catalog = ModelCatalog.bundled();

  test('every recommended model is in the catalogue', () {
    for (final pick in recommended) {
      expect(catalog[pick.id], isNotNull, reason: pick.id.value);
    }
  });

  test('grouping keeps every size, once, smallest first', () {
    final groups = groupCatalogue(catalog.available);
    final ids = [for (final g in groups) ...g.sizes.map((d) => d.id)];
    expect(ids.toSet(), catalog.available.map((d) => d.id).toSet());
    expect(ids.length, catalog.available.length);
    for (final g in groups) {
      expect(g.sizes.map((d) => d.variant).toSet(), {g.variant});
      for (var i = 1; i < g.sizes.length; i++) {
        expect(
          g.sizes[i].sizeBytes,
          greaterThanOrEqualTo(g.sizes[i - 1].sizeBytes),
        );
      }
    }
  });

  test('the suggested size is Q4_K_M where a model has one', () {
    final groups = groupCatalogue(catalog.available);
    final parakeet = groups.firstWhere(
      (g) => g.variant == 'parakeet-tdt_ctc-110m',
    );
    expect(parakeet.suggested.quant, 'Q4_K_M');
    final moonshine = groups.firstWhere(
      (g) => g.variant == 'moonshine-streaming-tiny',
    );
    expect(moonshine.suggested, moonshine.sizes.first);
  });

  test('sizes and languages read naturally', () {
    expect(formatBytes(89500000), '90 MB');
    expect(formatBytes(1200000000), '1.2 GB');
    expect(formatLanguages(['en']), 'English');
    expect(formatLanguages(['uk']), 'Ukrainian');
    expect(formatLanguages(['xx']), 'XX');
    expect(formatLanguages(List.filled(99, 'x')), '99 languages');
  });
}
