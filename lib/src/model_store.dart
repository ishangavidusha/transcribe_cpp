import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'catalog.dart';

/// A download that cannot be installed: wrong size or wrong SHA-256.
final class ModelIntegrityException implements Exception {
  ModelIntegrityException(this.id, this.message);

  final ModelId id;
  final String message;

  @override
  String toString() => 'ModelIntegrityException(${id.value}): $message';
}

/// Not enough free space to finish downloading a model.
final class InsufficientStorageException implements Exception {
  InsufficientStorageException(
    this.id,
    this.requiredBytes,
    this.availableBytes,
  );

  final ModelId id;
  final int requiredBytes;
  final int availableBytes;

  @override
  String toString() =>
      'InsufficientStorageException(${id.value}): needs $requiredBytes bytes, '
      '$availableBytes available';
}

/// Model files on disk: where they go, and the rule that only a verified file
/// is ever installed.
///
/// A model is `<id>.gguf` in [directory]. Bytes are written to `<id>.gguf.part`
/// first and renamed only after the size and SHA-256 match the descriptor. The
/// rename is the install, and it is atomic, so a file under the final name has
/// always been verified. An app killed mid-download leaves a `.part` that a
/// later download resumes from, never a `.gguf` that crashes the loader on
/// every launch.
///
/// One writer per id. Two downloads of the same model would interleave in one
/// `.part`; the model manager is what keeps them to one.
final class ModelStore {
  ModelStore(this.directory, {Future<int> Function()? freeBytes})
    : _freeBytes = freeBytes ?? _platformFreeBytes;

  /// The platform's model directory, created if needed.
  ///
  /// iOS: Application Support, excluded from iCloud backup. Android is not
  /// implemented yet and throws [MissingPluginException].
  static Future<ModelStore> open() async {
    final path = await _channel.invokeMethod<String>('modelDirectory');
    if (path == null) throw StateError('modelDirectory returned nothing');
    return ModelStore(Directory(path));
  }

  static const _channel = MethodChannel('transcribe_cpp/storage');

  static Future<int> _platformFreeBytes() async =>
      await _channel.invokeMethod<int>('freeBytes') ?? 0;

  final Directory directory;
  final Future<int> Function() _freeBytes;

  // Ids become file names, and an app can construct its own. Upstream's own
  // slug rule, which every bundled id meets, also rules out path separators
  // and `..`, so an id cannot name a file outside [directory].
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  /// Where [id] is installed. Exists only once installed.
  File fileOf(ModelId id) {
    if (!_safeId.hasMatch(id.value) || id.value.contains('..')) {
      throw ArgumentError.value(id.value, 'id', 'not a safe file name');
    }
    return File('${directory.path}/${id.value}.gguf');
  }

  File _partOf(ModelId id) => File('${fileOf(id).path}.part');

  /// Whether [model] is installed at its expected size.
  ///
  /// The hash is checked once, at install, not here: re-hashing a 1 GB file on
  /// every launch would cost seconds for no new information. The size check
  /// catches an entry whose file changed under the same id.
  Future<bool> isInstalled(ModelDescriptor model) async {
    final file = fileOf(model.id);
    return await file.exists() && await file.length() == model.sizeBytes;
  }

  /// Ids with a file installed, whatever catalogue they came from.
  Future<Set<ModelId>> installedIds() async {
    if (!await directory.exists()) return {};
    return {
      await for (final e in directory.list())
        if (e is File && e.path.endsWith('.gguf'))
          ModelId(e.uri.pathSegments.last.replaceFirst(RegExp(r'\.gguf$'), '')),
    };
  }

  /// Bytes already downloaded for [id], where a download resumes from.
  Future<int> partLength(ModelId id) async {
    final part = _partOf(id);
    return await part.exists() ? part.length() : 0;
  }

  /// Throws [InsufficientStorageException] unless the rest of [model] fits.
  ///
  /// Asks for 10% more than the remaining bytes, so that finishing a download
  /// never leaves the phone completely full. A download that fails at 87% has
  /// already filled the volume; checking first refuses it while nothing has
  /// been spent.
  Future<void> checkSpace(ModelDescriptor model) async {
    final remaining = model.sizeBytes - await partLength(model.id);
    final required = (remaining * 1.1).ceil();
    final available = await _freeBytes();
    if (available < required) {
      throw InsufficientStorageException(model.id, required, available);
    }
  }

  /// Writes [bytes] to [model]'s `.part`, after what is there if [append],
  /// and returns the part's new length.
  Future<int> writePart(
    ModelDescriptor model,
    Stream<List<int>> bytes, {
    bool append = false,
  }) async {
    await directory.create(recursive: true);
    final part = _partOf(model.id);
    final sink = part.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    try {
      await sink.addStream(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
    return part.length();
  }

  /// Verifies [model]'s `.part` and installs it, returning the model file.
  ///
  /// A part shorter than the descriptor is kept, since a download that stopped
  /// early can resume from it. A part that is too long or hashes wrong is
  /// deleted: no amount of resuming fixes it.
  Future<File> commit(ModelDescriptor model) async {
    final part = _partOf(model.id);
    if (!await part.exists()) {
      throw ModelIntegrityException(model.id, 'nothing downloaded');
    }
    final length = await part.length();
    if (length < model.sizeBytes) {
      throw ModelIntegrityException(
        model.id,
        'incomplete: $length of ${model.sizeBytes} bytes',
      );
    }
    if (length > model.sizeBytes) {
      await part.delete();
      throw ModelIntegrityException(
        model.id,
        '$length bytes, expected ${model.sizeBytes}',
      );
    }
    final digest = await _sha256(part.path);
    if (digest != model.sha256.toLowerCase()) {
      await part.delete();
      throw ModelIntegrityException(
        model.id,
        'SHA-256 $digest, expected ${model.sha256}',
      );
    }
    return part.rename(fileOf(model.id).path);
  }

  /// Deletes [id]'s installed file and any partial download.
  Future<void> remove(ModelId id) async {
    for (final f in [fileOf(id), _partOf(id)]) {
      if (await f.exists()) await f.delete();
    }
  }

  /// Bytes used by installed models and partial downloads together.
  Future<int> bytesOnDisk() async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final e in directory.list()) {
      if (e is File &&
          (e.path.endsWith('.gguf') || e.path.endsWith('.gguf.part'))) {
        total += await e.length();
      }
    }
    return total;
  }
}

/// Hashes the file as written, not the bytes as received, so a write that
/// went wrong on the way to disk fails too. Runs on its own isolate: the
/// whole file passes through it, and the caller is usually the UI isolate.
///
/// package:crypto, AOT on an Apple-silicon Mac: 470 ms for parakeet-110m's
/// 90 MB, about 190 MB/s, so roughly 5 s for a 1 GB model. Not yet measured
/// on a phone.
Future<String> _sha256(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);
