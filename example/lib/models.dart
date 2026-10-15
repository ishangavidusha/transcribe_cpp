import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// A few good starting points, shown above the full catalogue.
const recommended = <({ModelId id, String title, String note})>[
  (
    id: ModelId('parakeet-tdt_ctc-110m-Q4_K_M'),
    title: 'Parakeet 110M',
    note: 'English. 2.5% word error rate on LibriSpeech.',
  ),
  (
    id: ModelId('moonshine-streaming-tiny-Q8_0'),
    title: 'Moonshine Streaming Tiny',
    note: 'English. About half the size of Parakeet.',
  ),
  (
    id: ModelId('whisper-base-Q4_K_M'),
    title: 'Whisper Base',
    note: '99 languages.',
  ),
];

/// One model, in every size the catalogue offers it.
class ModelGroup {
  ModelGroup(this.sizes);

  /// Smallest first.
  final List<ModelDescriptor> sizes;

  ModelDescriptor get first => sizes.first;
  String get name => first.displayName;
  String get variant => first.variant;

  /// The size to offer by default: Q4_K_M where there is one, which loses
  /// little accuracy for a much smaller file, otherwise the smallest.
  ModelDescriptor get suggested =>
      sizes.firstWhere((d) => d.quant == 'Q4_K_M', orElse: () => first);
}

/// The catalogue grouped by model, smallest model first.
List<ModelGroup> groupCatalogue(List<ModelDescriptor> available) {
  final byVariant = <String, List<ModelDescriptor>>{};
  for (final d in available) {
    byVariant.putIfAbsent(d.variant, () => []).add(d);
  }
  final groups = [
    for (final sizes in byVariant.values)
      ModelGroup(sizes..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes))),
  ];
  groups.sort((a, b) => a.first.sizeBytes.compareTo(b.first.sizeBytes));
  return groups;
}

String formatBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  return '${(bytes / 1e6).round()} MB';
}

String formatParameters(int parameters) => parameters >= 1000000000
    ? '${(parameters / 1e9).toStringAsFixed(1)}B parameters'
    : '${(parameters / 1e6).round()}M parameters';

String formatLanguages(List<String> languages) {
  if (languages.length > 4) return '${languages.length} languages';
  return languages.map((l) => _languageNames[l] ?? l.toUpperCase()).join(', ');
}

/// The languages single-language models in the catalogue are for. Codes
/// alone mislead: `uk` is Ukrainian.
const _languageNames = {
  'ar': 'Arabic',
  'de': 'German',
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'vi': 'Vietnamese',
  'zh': 'Chinese',
};

/// Remembers the chosen model across launches.
abstract final class ModelChoice {
  static Future<File> get _file async =>
      File('${(await getApplicationSupportDirectory()).path}/model_choice');

  static Future<ModelId?> load() async {
    try {
      final value = (await (await _file).readAsString()).trim();
      return value.isEmpty ? null : ModelId(value);
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> save(ModelId id) async =>
      (await _file).writeAsString(id.value);
}
