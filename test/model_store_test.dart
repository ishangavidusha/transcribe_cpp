import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/catalog.dart';
import 'package:transcribe_cpp/src/model_store.dart';

final _bytes = Uint8List.fromList(List.generate(10000, (i) => i * 31 % 256));

ModelDescriptor _model(
  List<int> bytes, {
  String id = 'test-model-Q8_0',
  String? sha,
}) => ModelDescriptor(
  id: ModelId(id),
  variant: 'test-model',
  quant: 'Q8_0',
  family: 'parakeet',
  displayName: 'test',
  languages: const ['en'],
  license: 'mit',
  parameters: 1,
  sizeBytes: bytes.length,
  sha256: sha ?? sha256.convert(bytes).toString(),
  url: Uri.parse('file:///dev/null'),
);

Stream<List<int>> _stream(List<int> bytes) => Stream.value(bytes);

void main() {
  late Directory dir;
  late ModelStore store;
  var free = 1 << 40;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('model_store_test');
    free = 1 << 40;
    store = ModelStore(dir, freeBytes: () async => free);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('install', () {
    test('a verified download is installed under its final name', () async {
      final m = _model(_bytes);
      expect(await store.writePart(m, _stream(_bytes)), _bytes.length);
      final file = await store.commit(m);
      expect(file.path, store.fileOf(m.id).path);
      expect(await file.readAsBytes(), _bytes);
      expect(await store.isInstalled(m), isTrue);
      expect(await store.installedIds(), {m.id});
      expect(await store.partLength(m.id), 0, reason: 'the part is renamed');
    });

    test('a download resumes by appending to the part', () async {
      final m = _model(_bytes);
      await store.writePart(m, _stream(_bytes.sublist(0, 4000)));
      expect(await store.partLength(m.id), 4000);
      await store.writePart(m, _stream(_bytes.sublist(4000)), append: true);
      await store.commit(m);
      expect(await store.isInstalled(m), isTrue);
    });

    test('a wrong hash is deleted and never installed', () async {
      final m = _model(_bytes, sha: 'ab' * 32);
      await store.writePart(m, _stream(_bytes));
      await expectLater(
        store.commit(m),
        throwsA(isA<ModelIntegrityException>()),
      );
      expect(await store.isInstalled(m), isFalse);
      expect(await store.partLength(m.id), 0);
      expect(store.fileOf(m.id).existsSync(), isFalse);
    });

    test('a short part is kept for resuming, not installed', () async {
      final m = _model(_bytes);
      await store.writePart(m, _stream(_bytes.sublist(0, 100)));
      await expectLater(
        store.commit(m),
        throwsA(isA<ModelIntegrityException>()),
      );
      expect(await store.partLength(m.id), 100);
      expect(await store.isInstalled(m), isFalse);
    });

    test('a part longer than the model is deleted', () async {
      final m = _model(_bytes);
      await store.writePart(m, _stream([..._bytes, 0]));
      await expectLater(
        store.commit(m),
        throwsA(isA<ModelIntegrityException>()),
      );
      expect(await store.partLength(m.id), 0);
    });

    test('committing with nothing downloaded fails', () async {
      await expectLater(
        store.commit(_model(_bytes)),
        throwsA(isA<ModelIntegrityException>()),
      );
    });

    test('an upper-case hash in a descriptor still matches', () async {
      final m = _model(
        _bytes,
        sha: sha256.convert(_bytes).toString().toUpperCase(),
      );
      await store.writePart(m, _stream(_bytes));
      await store.commit(m);
      expect(await store.isInstalled(m), isTrue);
    });
  });

  test('a file of the wrong size does not count as installed', () async {
    final m = _model(_bytes);
    await store.writePart(m, _stream(_bytes));
    await store.commit(m);
    final changed = _model([..._bytes, 1], sha: m.sha256);
    expect(await store.isInstalled(changed), isFalse);
  });

  test('remove deletes the model and any partial download', () async {
    final a = _model(_bytes, id: 'a');
    final b = _model(_bytes, id: 'b');
    await store.writePart(a, _stream(_bytes));
    await store.commit(a);
    await store.writePart(b, _stream(_bytes.sublist(0, 10)));
    await store.remove(a.id);
    await store.remove(b.id);
    expect(await store.installedIds(), isEmpty);
    expect(await store.bytesOnDisk(), 0);
  });

  test('bytesOnDisk counts models and parts and nothing else', () async {
    final a = _model(_bytes, id: 'a');
    await store.writePart(a, _stream(_bytes));
    await store.commit(a);
    await store.writePart(
      _model(_bytes, id: 'b'),
      _stream(_bytes.sublist(0, 7)),
    );
    File('${dir.path}/notes.txt').writeAsStringSync('not a model');
    expect(await store.bytesOnDisk(), _bytes.length + 7);
    expect(await store.installedIds(), {const ModelId('a')});
  });

  group('checkSpace', () {
    test('passes with room for the model plus 10%', () async {
      free = (_bytes.length * 1.1).ceil();
      await store.checkSpace(_model(_bytes));
    });

    test('refuses before a byte is written, naming the numbers', () async {
      free = _bytes.length;
      await expectLater(
        store.checkSpace(_model(_bytes)),
        throwsA(
          isA<InsufficientStorageException>()
              .having((e) => e.requiredBytes, 'required', 11000)
              .having((e) => e.availableBytes, 'available', _bytes.length),
        ),
      );
    });

    test('counts only what is left to download', () async {
      final m = _model(_bytes);
      await store.writePart(m, _stream(_bytes.sublist(0, 9000)));
      free = 1100;
      await store.checkSpace(m);
    });
  });

  test('ids that could leave the directory are refused', () {
    for (final bad in ['../escape', 'a/b', '', '.hidden', 'a..b']) {
      expect(
        () => store.fileOf(ModelId(bad)),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(
      store.fileOf(const ModelId('whisper-base.en-Q8_0')).path,
      endsWith('/whisper-base.en-Q8_0.gguf'),
    );
  });

  test('every bundled id is a safe file name', () {
    for (final e in ModelCatalog.bundled().entries) {
      store.fileOf(e.id);
    }
  });

  test('installedIds and bytesOnDisk tolerate a missing directory', () async {
    final missing = ModelStore(Directory('${dir.path}/absent'));
    expect(await missing.installedIds(), isEmpty);
    expect(await missing.bytesOnDisk(), 0);
  });

  group('open', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('transcribe_cpp/storage');
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('uses the directory and free space the platform reports', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'modelDirectory' => dir.path,
              'freeBytes' => 5,
              _ => null,
            };
          });
      final opened = await ModelStore.open();
      expect(opened.directory.path, dir.path);
      await expectLater(
        opened.checkSpace(_model(_bytes)),
        throwsA(
          isA<InsufficientStorageException>().having(
            (e) => e.availableBytes,
            'available',
            5,
          ),
        ),
      );
    });
  });
}
