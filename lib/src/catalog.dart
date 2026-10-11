part 'catalog.g.dart';

/// Names one downloadable model file, such as `parakeet-tdt_ctc-110m-Q4_K_M`.
///
/// One id is one `.gguf`: a model at one quantization. The bundled ids are the
/// file names without the extension, so they read the same on Hugging Face.
extension type const ModelId(String value) {}

/// Everything needed to fetch, verify and identify one model file.
///
/// The bundled entries come from [ModelCatalog.bundled]. Construct one
/// directly for a model the catalogue does not list, such as a fine-tune on
/// your own server.
final class ModelDescriptor {
  const ModelDescriptor({
    required this.id,
    required this.variant,
    required this.quant,
    required this.family,
    required this.displayName,
    required this.languages,
    required this.license,
    required this.parameters,
    required this.sizeBytes,
    required this.sha256,
    required this.url,
  });

  final ModelId id;

  /// The model, independent of quantization: `parakeet-tdt_ctc-110m`. Group
  /// by this to offer one row per model and a separate size choice.
  final String variant;

  /// GGUF quantization, such as `Q4_K_M` or `F16`. Smaller files cost a
  /// little accuracy: parakeet-110m's LibriSpeech WER is 2.43% at Q8_0 and
  /// 2.53% at Q4_K_M, per transcribe.cpp's catalogue.
  final String quant;

  /// The engine loader that runs it — the GGUF's `general.architecture`, in
  /// transcribe.cpp's catalogue spelling. [ModelCatalog.available] hides
  /// families the linked engine does not have.
  final String family;

  final String displayName;

  /// Languages it transcribes, in the spellings the model advertises.
  final List<String> languages;

  /// SPDX identifier, or `other` for a licence without one. Check it before
  /// shipping a model in a commercial app: they differ.
  final String license;

  final int parameters;

  /// Exact size of the file, for disk-space checks and progress.
  final int sizeBytes;

  /// Lower-case hex SHA-256 of the file. A download is installed only if it
  /// matches, so a truncated or corrupted file is never loaded.
  final String sha256;

  /// Where to fetch it. Bundled entries pin a Hugging Face commit, so the
  /// bytes behind the URL cannot change under [sha256].
  final Uri url;

  @override
  String toString() => 'ModelDescriptor($id, $sizeBytes bytes)';
}

/// The models an app can offer.
///
/// The package does not choose a model for the app or download anything on
/// its own. The catalogue only describes what exists; the app decides which
/// entries to show, if any, and when to fetch them.
final class ModelCatalog {
  /// A catalogue of exactly [entries]: for an app that offers its own list.
  ModelCatalog(Iterable<ModelDescriptor> entries) : this._(entries.toList());

  ModelCatalog._(List<ModelDescriptor> entries)
    : entries = List.unmodifiable(entries),
      _byId = {for (final e in entries) e.id: e} {
    if (_byId.length != entries.length) {
      final seen = <ModelId>{};
      final dup = entries.firstWhere((e) => !seen.add(e.id)).id;
      throw ArgumentError.value(dup.value, 'entries', 'duplicate model id');
    }
  }

  /// Every transcription model transcribe.cpp publishes whose file is 1 GB
  /// or less, at every such quantization.
  ///
  /// Generated from the catalogue of the same engine release this package
  /// links, so every entry loads. Being listed is not a recommendation for a
  /// phone: whisper-large at 1 GB fits the limit, but has not been run on one
  /// through this package. parakeet-tdt_ctc-110m and moonshine-streaming-tiny
  /// have, on an iPhone 12 Pro.
  factory ModelCatalog.bundled() => ModelCatalog._(_bundled());

  /// The engine release the bundled entries were generated from.
  static const engineRelease = _engineRef;

  /// Everything this catalogue was given, in order.
  final List<ModelDescriptor> entries;

  final Map<ModelId, ModelDescriptor> _byId;

  /// The entries the linked engine can load.
  ///
  /// Filters by [ModelDescriptor.family] only. A newer model in a family the
  /// engine knows can still need a newer engine; that surfaces as a load
  /// error naming the variant, not as a crash.
  List<ModelDescriptor> get available =>
      entries.where((e) => supportsFamily(e.family)).toList(growable: false);

  /// The entry for [id], or null if this catalogue does not list it.
  ModelDescriptor? operator [](ModelId id) => _byId[id];

  /// This catalogue plus [extra], for an app that offers the bundled models
  /// and some of its own. An id already present is an error, not an override.
  ModelCatalog withEntries(Iterable<ModelDescriptor> extra) =>
      ModelCatalog._([...entries, ...extra]);

  /// Whether the linked engine has a loader for [family].
  static bool supportsFamily(String family) => _families.contains(family);
}
