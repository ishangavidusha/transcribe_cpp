import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/model_manager.dart';
import 'package:transcribe_cpp/src/model_store.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

final _bytes = Uint8List.fromList(
  List.generate(2 << 20, (i) => (i * 13 + (i >> 9)) % 256),
);

/// Serves [_bytes] for any path, slowly enough to cancel part-way. Honours
/// ranges, and can cut the connection after [truncateAt] bytes.
class _Server {
  late HttpServer _http;
  final requests = <HttpRequest>[];
  int? truncateAt;

  Uri url(String id) => Uri.parse('http://127.0.0.1:${_http.port}/$id.gguf');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      requests.add(req);
      final res = req.response;
      var from = 0;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $from-${_bytes.length - 1}/${_bytes.length}',
        );
      }
      res.contentLength = _bytes.length - from;
      if (truncateAt != null) {
        final socket = await res.detachSocket();
        socket.add(_bytes.sublist(from, truncateAt));
        await socket.flush();
        socket.destroy();
        return;
      }
      for (var i = from; i < _bytes.length; i += 64 * 1024) {
        final end = i + 64 * 1024 > _bytes.length
            ? _bytes.length
            : i + 64 * 1024;
        res.add(_bytes.sublist(i, end));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await res.close();
    });
  }

  Future<void> close() => _http.close(force: true);
}

ModelDescriptor _model(Uri url, String id, {String family = 'parakeet'}) =>
    ModelDescriptor(
      id: ModelId(id),
      variant: id,
      quant: 'Q8_0',
      family: family,
      displayName: id,
      languages: const ['en'],
      license: 'mit',
      parameters: 1,
      sizeBytes: _bytes.length,
      sha256: sha256.convert(_bytes).toString(),
      url: url,
    );

void main() {
  late Directory dir;
  late ModelStore store;
  late _Server server;
  late ModelCatalog catalog;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('model_manager_test');
    store = ModelStore(dir, freeBytes: () async => 1 << 40);
    server = _Server();
    await server.start();
    catalog = ModelCatalog([
      for (final id in ['a', 'b', 'c']) _model(server.url(id), id),
      _model(server.url('future'), 'future', family: 'not_a_family'),
    ]);
  });
  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  Future<ModelManager> open() => createModelManager(catalog, store);

  Future<void> install(String id) async {
    final m = catalog[ModelId(id)]!;
    await store.writePart(m, Stream.value(_bytes));
    await store.commit(m);
  }

  /// Every value [live] publishes from now until [done] completes, starting
  /// with its current one.
  Future<List<T>> record<T>(Live<T> live, Future<void> done) async {
    final seen = <T>[];
    final sub = live.stream.listen(seen.add);
    await done;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    return seen;
  }

  test('reads what is on disk before returning', () async {
    await install('a');
    await store.writePart(catalog[const ModelId('b')]!, Stream.value([1, 2]));
    File('${dir.path}/orphan.gguf').writeAsBytesSync([0]);

    final models = await open();
    expect(models.installed.value, {
      const ModelId('a'): ModelStatus.installed,
      const ModelId('b'): ModelStatus.partial,
      const ModelId('c'): ModelStatus.notInstalled,
      const ModelId('future'): ModelStatus.notInstalled,
      const ModelId('orphan'): ModelStatus.installed,
    });
  });

  test('available leaves out what the engine cannot load', () async {
    final models = await open();
    expect(models.available.map((m) => m.id.value), ['a', 'b', 'c']);
  });

  test('ensure downloads and reports each status in turn', () async {
    final models = await open();
    final done = models.ensure(const ModelId('a'));
    final statuses = record(
      models.installed,
      done,
    ).then((maps) => [for (final m in maps) m[const ModelId('a')]]);
    final installed = await done;
    expect(await statuses, [ModelStatus.downloading, ModelStatus.installed]);
    expect(installed.path, store.fileOf(const ModelId('a')).path);
    expect(File(installed.path).readAsBytesSync(), _bytes);
  });

  test('ensure on an installed model returns it without a request', () async {
    await install('a');
    final models = await open();
    final installed = await models.ensure(const ModelId('a'));
    expect(installed.descriptor.id, const ModelId('a'));
    expect(server.requests, isEmpty);
  });

  test('progressOf is live only while downloading', () async {
    final models = await open();
    expect(models.progressOf(const ModelId('a')), isNull);
    final done = models.ensure(const ModelId('a'));
    expect(models.progressOf(const ModelId('a')), isNotNull);
    await done;
    await Future<void>.delayed(Duration.zero);
    expect(models.progressOf(const ModelId('a')), isNull);
  });

  test('a cancelled download is left partial and resumes', () async {
    final models = await open();
    final token = CancelToken();
    final done = models.ensure(const ModelId('a'), cancel: token);
    await models
        .progressOf(const ModelId('a'))!
        .stream
        .firstWhere((p) => p.receivedBytes >= 1 << 20);
    token.cancel();
    await expectLater(done, throwsA(isA<DownloadCancelledException>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(models.installed.value[const ModelId('a')], ModelStatus.partial);

    await models.ensure(const ModelId('a'));
    expect(models.installed.value[const ModelId('a')], ModelStatus.installed);
    expect(server.requests.last.headers.value('range'), isNotNull);
  });

  test('a failed download is left partial', () async {
    server.truncateAt = 1 << 20;
    final models = await open();
    await expectLater(
      models.ensure(const ModelId('a')),
      throwsA(isA<ModelDownloadException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(models.installed.value[const ModelId('a')], ModelStatus.partial);
  });

  test('one caller cancelling leaves the shared download running', () async {
    final models = await open();
    final token = CancelToken();
    final cancelled = models.ensure(const ModelId('a'), cancel: token);
    final kept = models.ensure(const ModelId('a'));
    token.cancel();
    await expectLater(cancelled, throwsA(isA<DownloadCancelledException>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(models.installed.value[const ModelId('a')], ModelStatus.downloading);
    await kept;
    await Future<void>.delayed(Duration.zero);
    expect(models.installed.value[const ModelId('a')], ModelStatus.installed);
  });

  test('a request right after a cancel ends installed, not stuck', () async {
    final models = await open();
    final token = CancelToken();
    final first = models.ensure(const ModelId('a'), cancel: token);
    await models
        .progressOf(const ModelId('a'))!
        .stream
        .firstWhere((p) => p.receivedBytes >= 1 << 20);
    token.cancel();
    await expectLater(first, throwsA(isA<DownloadCancelledException>()));
    // The cancelled transfer may still be closing its file here.
    final second = models.ensure(const ModelId('a'));
    await second;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(models.installed.value[const ModelId('a')], ModelStatus.installed);
  });

  test('ensure refuses an unknown id and an unloadable family', () async {
    final models = await open();
    expect(() => models.ensure(const ModelId('nope')), throwsArgumentError);
    expect(
      () => models.ensure(const ModelId('future')),
      throwsUnsupportedError,
    );
    expect(server.requests, isEmpty);
  });

  test('remove deletes and reports not installed', () async {
    await install('a');
    final models = await open();
    await models.remove(const ModelId('a'));
    expect(
      models.installed.value[const ModelId('a')],
      ModelStatus.notInstalled,
    );
    expect(await models.bytesOnDisk(), 0);
  });

  test('remove of an unlisted file drops its row', () async {
    File('${dir.path}/orphan.gguf').writeAsBytesSync([0]);
    final models = await open();
    await models.remove(const ModelId('orphan'));
    expect(
      models.installed.value.containsKey(const ModelId('orphan')),
      isFalse,
    );
  });

  test('remove refuses while downloading', () async {
    final models = await open();
    final done = models.ensure(const ModelId('a'));
    await expectLater(models.remove(const ModelId('a')), throwsStateError);
    await done;
  });

  test('bytesOnDisk counts installed and partial files', () async {
    await install('a');
    await store.writePart(catalog[const ModelId('b')]!, Stream.value([1, 2]));
    final models = await open();
    expect(await models.bytesOnDisk(), _bytes.length + 2);
  });
}
