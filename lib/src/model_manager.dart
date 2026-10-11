import 'dart:async';

import 'catalog.dart';
import 'live.dart';
import 'model_download.dart';
import 'model_store.dart';

/// Where one model stands on this device.
enum ModelStatus {
  /// Nothing on disk.
  notInstalled,

  /// A download stopped part-way; [ModelManager.ensure] resumes it.
  partial,

  /// Being downloaded now. [ModelManager.progressOf] has the numbers.
  downloading,

  /// Downloaded, verified and ready to load.
  installed,
}

/// A model file that is on disk and has passed its hash check.
final class InstalledModel {
  const InstalledModel._(this.descriptor, this.path);

  final ModelDescriptor descriptor;

  /// Absolute path to the `.gguf`, for loading.
  final String path;

  @override
  String toString() => 'InstalledModel(${descriptor.id.value}, $path)';
}

/// Downloads, stores and tracks the models an app offers.
///
/// The package never picks a model or downloads one on its own. The app
/// decides which entries to show and calls [ensure] when it wants one: on
/// first launch behind a loading screen, from a picker, or not at all.
///
/// ```dart
/// final models = await ModelManager.open();
/// final model = await models.ensure(const ModelId('parakeet-tdt_ctc-110m-Q4_K_M'));
/// ```
final class ModelManager {
  ModelManager._(
    this.catalog,
    this._store,
    this._downloader,
    Map<ModelId, ModelStatus> initial,
  ) : _status = LiveController(Map.unmodifiable(initial));

  /// Opens the platform's model directory and reads what is already there.
  ///
  /// Async so that [installed] is right from its first value: a picker built
  /// from it never shows "Download" for a model that is on disk.
  ///
  /// [catalog] defaults to [ModelCatalog.bundled].
  static Future<ModelManager> open({ModelCatalog? catalog}) async =>
      createModelManager(
        catalog ?? ModelCatalog.bundled(),
        await ModelStore.open(),
      );

  /// What this manager knows how to fetch.
  final ModelCatalog catalog;

  final ModelStore _store;
  final ModelDownloader _downloader;
  final LiveController<Map<ModelId, ModelStatus>> _status;
  final _generation = <ModelId, int>{};

  /// The catalogue entries the linked engine can load. A picker should list
  /// these, not [ModelCatalog.entries].
  List<ModelDescriptor> get available => catalog.available;

  /// The status of every catalogue entry, plus any model file on disk the
  /// catalogue no longer lists, so an app can still find and remove it.
  Live<Map<ModelId, ModelStatus>> get installed => _status.live;

  /// Progress of [id]'s download, or null when it is not downloading.
  Live<DownloadProgress>? progressOf(ModelId id) => _downloader.progressOf(id);

  /// Returns [id] installed, downloading it first if it is not.
  ///
  /// Idempotent and shared: callers asking for a model already on its way
  /// wait for the same download, and each can [CancelToken.cancel] its own
  /// wait without stopping the others. A cancelled or failed download keeps
  /// what it received, and the next call resumes from there.
  ///
  /// Throws [ArgumentError] for an id not in [catalog], [UnsupportedError]
  /// for a model the linked engine cannot load, and otherwise one of
  /// [InsufficientStorageException], [ModelDownloadException],
  /// [ModelIntegrityException] or [DownloadCancelledException].
  Future<InstalledModel> ensure(ModelId id, {CancelToken? cancel}) async {
    final model = catalog[id];
    if (model == null) {
      throw ArgumentError.value(id.value, 'id', 'not in the catalogue');
    }
    if (!ModelCatalog.supportsFamily(model.family)) {
      throw UnsupportedError(
        '${id.value} is a ${model.family} model, which this build of the '
        'engine (${ModelCatalog.engineRelease}) cannot load',
      );
    }
    if (_status.value[id] == ModelStatus.installed &&
        await _store.isInstalled(model)) {
      return InstalledModel._(model, _store.fileOf(id).path);
    }

    // Compared by identity, not null-checked: a request arriving while a
    // cancelled transfer is still closing starts a new one, and that new one
    // is what must be watched.
    final before = _downloader.transferOf(id);
    final file = _downloader.download(model, cancel: cancel);
    final transfer = _downloader.transferOf(id);
    if (transfer != null && !identical(transfer, before)) {
      _set(id, ModelStatus.downloading);
      // The transfer, not this caller, decides when the download is over:
      // this caller may cancel while others keep it going.
      unawaited(transfer.then((_) => _refresh(id)));
    }
    final path = (await file).path;
    // Set here, not left to the transfer's end: a caller that awaits this and
    // then reads [installed] must see the model as installed.
    _set(id, ModelStatus.installed);
    return InstalledModel._(model, path);
  }

  /// Deletes [id]'s file and any partial download.
  ///
  /// Throws [StateError] while it is downloading: another part of the app
  /// may be waiting for it. Cancel the download first.
  Future<void> remove(ModelId id) async {
    if (_downloader.transferOf(id) != null) {
      throw StateError('${id.value} is downloading; cancel it first');
    }
    await _store.remove(id);
    await _refresh(id);
  }

  /// Bytes used by installed models and partial downloads.
  Future<int> bytesOnDisk() => _store.bytesOnDisk();

  void _set(ModelId id, ModelStatus status) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    if (_status.value[id] == status) return;
    _status.value = Map.unmodifiable({..._status.value, id: status});
  }

  /// Reads [id]'s status back from disk. A later change made while this was
  /// reading wins, so a slow read cannot overwrite "downloading" with what
  /// was on disk before the download began.
  Future<void> _refresh(ModelId id) async {
    if (_downloader.transferOf(id) != null) {
      _set(id, ModelStatus.downloading);
      return;
    }
    final generation = _generation[id] ?? 0;
    final status = await _statusOnDisk(_store, catalog[id], id);
    if ((_generation[id] ?? 0) != generation) return;
    if (status == ModelStatus.notInstalled && catalog[id] == null) {
      // An unlisted file that is gone is no longer worth a row.
      _generation[id] = generation + 1;
      _status.value = Map.unmodifiable({..._status.value}..remove(id));
      return;
    }
    _set(id, status);
  }
}

Future<ModelStatus> _statusOnDisk(
  ModelStore store,
  ModelDescriptor? model,
  ModelId id,
) async {
  final installed = model != null
      ? await store.isInstalled(model)
      : await store.fileOf(id).exists();
  if (installed) return ModelStatus.installed;
  return await store.partLength(id) > 0
      ? ModelStatus.partial
      : ModelStatus.notInstalled;
}

/// Builds a manager over [store]. Not exported: [ModelManager.open] is the
/// public way in, and tests use this to point it at a temporary directory.
Future<ModelManager> createModelManager(
  ModelCatalog catalog,
  ModelStore store, {
  ModelDownloader? downloader,
}) async {
  final status = <ModelId, ModelStatus>{
    for (final e in catalog.entries) e.id: await _statusOnDisk(store, e, e.id),
    for (final id in await store.installedIds())
      if (catalog[id] == null) id: ModelStatus.installed,
  };
  return ModelManager._(
    catalog,
    store,
    downloader ?? ModelDownloader(store),
    status,
  );
}
