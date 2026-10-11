import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/catalog.dart';
import 'package:transcribe_cpp/src/model_download.dart';
import 'package:transcribe_cpp/src/model_store.dart';

// 3 MiB, so progress crosses its 1 MiB reporting step more than once.
final _bytes = Uint8List.fromList(
  List.generate(3 << 20, (i) => (i * 7 + (i >> 10)) % 256),
);

/// A file server that can be told to misbehave. Records every request.
class _Server {
  late HttpServer _http;
  final requests = <HttpRequest>[];

  /// Serves the bytes at /model.gguf. Set any of these to break it.
  bool honourRange = true;
  int? status;
  int? truncateAt;
  bool stall = false;
  Duration chunkDelay = Duration.zero;
  List<int> body = _bytes;
  String? redirectTo;
  bool refuseRangeOnce = false;

  Uri get url => Uri.parse('http://127.0.0.1:${_http.port}/model.gguf');
  Uri get otherHostUrl =>
      Uri.parse('http://localhost:${_http.port}/model.gguf');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen(_handle);
  }

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    requests.add(req);
    final res = req.response;
    if (redirectTo != null && req.uri.path == '/model.gguf') {
      final target = redirectTo!;
      redirectTo = null;
      res.statusCode = HttpStatus.found;
      res.headers.set(HttpHeaders.locationHeader, target);
      await res.close();
      return;
    }
    if (status != null) {
      res.statusCode = status!;
      await res.close();
      return;
    }
    var from = 0;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null && refuseRangeOnce) {
      refuseRangeOnce = false;
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await res.close();
      return;
    }
    if (range != null && honourRange) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (from >= body.length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $from-${body.length - 1}/${body.length}',
      );
    }
    res.contentLength = body.length - from;
    if (stall) {
      res.add(body.sublist(from, from + (256 << 10)));
      await res.flush();
      return; // never finishes
    }
    if (truncateAt != null) {
      // Promise the whole body, send part of it, then drop the connection.
      final socket = await res.detachSocket();
      socket.add(body.sublist(from, truncateAt));
      await socket.flush();
      socket.destroy();
      return;
    }
    for (var i = from; i < body.length; i += 64 * 1024) {
      final end = i + 64 * 1024 > body.length ? body.length : i + 64 * 1024;
      res.add(body.sublist(i, end));
      await res.flush();
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
    }
    await res.close();
  }
}

ModelDescriptor _model(Uri url, {Map<String, String> headers = const {}}) =>
    ModelDescriptor(
      id: const ModelId('m-Q8_0'),
      variant: 'm',
      quant: 'Q8_0',
      family: 'parakeet',
      displayName: 'm',
      languages: const ['en'],
      license: 'mit',
      parameters: 1,
      sizeBytes: _bytes.length,
      sha256: sha256.convert(_bytes).toString(),
      url: url,
      headers: headers,
    );

void main() {
  late Directory dir;
  late ModelStore store;
  late ModelDownloader downloader;
  late _Server server;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('model_download_test');
    store = ModelStore(dir, freeBytes: () async => 1 << 40);
    downloader = ModelDownloader(
      store,
      idleTimeout: const Duration(milliseconds: 500),
    );
    server = _Server();
    await server.start();
  });
  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> partOf(int n) async {
    final m = _model(server.url);
    await store.writePart(m, Stream.value(_bytes.sublist(0, n)));
  }

  test('downloads, verifies and installs', () async {
    final m = _model(server.url);
    final file = await downloader.download(m);
    expect(await file.readAsBytes(), _bytes);
    expect(await store.isInstalled(m), isTrue);
    expect(server.requests.single.headers.value('range'), isNull);
  });

  test('an installed model is returned without a request', () async {
    final m = _model(server.url);
    await downloader.download(m);
    await downloader.download(m);
    expect(server.requests, hasLength(1));
  });

  test('resumes a partial download with a range request', () async {
    await partOf(1000000);
    final m = _model(server.url);
    await downloader.download(m);
    expect(server.requests.single.headers.value('range'), 'bytes=1000000-');
    expect(await store.fileOf(m.id).readAsBytes(), _bytes);
  });

  test('starts over when the server ignores the range', () async {
    server.honourRange = false;
    await partOf(1000000);
    final m = _model(server.url);
    await downloader.download(m);
    expect(await store.fileOf(m.id).readAsBytes(), _bytes);
  });

  test('starts over once when the server refuses the range', () async {
    // The server's file changed since the part was written, and it says so
    // with 416. The part is discarded and the download starts from zero.
    server.refuseRangeOnce = true;
    await partOf(1000000);
    final m = _model(server.url);
    await downloader.download(m);
    expect(server.requests, hasLength(2));
    expect(server.requests.last.headers.value('range'), isNull);
    expect(await store.fileOf(m.id).readAsBytes(), _bytes);
  });

  test('a dropped connection keeps the bytes, and the retry resumes', () async {
    server.truncateAt = 2000000;
    final m = _model(server.url);
    await expectLater(
      downloader.download(m),
      throwsA(isA<ModelDownloadException>()),
    );
    final kept = await store.partLength(m.id);
    expect(kept, greaterThan(0));
    expect(await store.isInstalled(m), isFalse);

    server.truncateAt = null;
    await downloader.download(m);
    expect(server.requests.last.headers.value('range'), 'bytes=$kept-');
    expect(await store.fileOf(m.id).readAsBytes(), _bytes);
  });

  test('wrong bytes are rejected by the hash and not kept', () async {
    server.body = List.filled(_bytes.length, 7);
    final m = _model(server.url);
    await expectLater(
      downloader.download(m),
      throwsA(isA<ModelIntegrityException>()),
    );
    expect(await store.partLength(m.id), 0);
    expect(await store.isInstalled(m), isFalse);
  });

  test('a file of the wrong length is refused before it is written', () async {
    server.body = _bytes.sublist(0, 100);
    final m = _model(server.url);
    await expectLater(
      downloader.download(m),
      throwsA(isA<ModelDownloadException>()),
    );
    expect(await store.partLength(m.id), 0);
  });

  test('access denied names the model and suggests a token', () async {
    server.status = HttpStatus.unauthorized;
    await expectLater(
      downloader.download(_model(server.url)),
      throwsA(
        isA<ModelDownloadException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.message, 'message', contains('token'))
            .having((e) => e.id.value, 'id', 'm-Q8_0'),
      ),
    );
  });

  test('a silent connection fails instead of hanging', () async {
    server.stall = true;
    final m = _model(server.url);
    await expectLater(
      downloader.download(m),
      throwsA(isA<ModelDownloadException>()),
    );
    expect(await store.partLength(m.id), greaterThan(0));
  });

  test('insufficient space is refused without a request', () async {
    final tight = ModelDownloader(ModelStore(dir, freeBytes: () async => 10));
    await expectLater(
      tight.download(_model(server.url)),
      throwsA(isA<InsufficientStorageException>()),
    );
    expect(server.requests, isEmpty);
  });

  group('redirects', () {
    test('are followed, keeping the range', () async {
      server.redirectTo = '/elsewhere/model.gguf';
      await partOf(5000);
      final m = _model(server.url);
      await downloader.download(m);
      expect(server.requests, hasLength(2));
      expect(server.requests.last.uri.path, '/elsewhere/model.gguf');
      expect(server.requests.last.headers.value('range'), 'bytes=5000-');
    });

    test("keep the app's headers on the same host", () async {
      server.redirectTo = '/elsewhere/model.gguf';
      await downloader.download(
        _model(server.url, headers: {'X-Api-Key': 'secret'}),
      );
      expect(server.requests.last.headers.value('x-api-key'), 'secret');
    });

    test("never carry the app's headers to another host", () async {
      server.redirectTo = server.otherHostUrl.toString();
      await downloader.download(
        _model(
          server.url,
          headers: {'Authorization': 'Bearer secret', 'X-Api-Key': 'secret'},
        ),
      );
      final last = server.requests.last;
      expect(last.headers.host, 'localhost');
      expect(last.headers.value('authorization'), isNull);
      expect(last.headers.value('x-api-key'), isNull);
      expect(server.requests.first.headers.value('x-api-key'), 'secret');
    });
  });

  group('progress', () {
    test('rises to the full size and is gone once finished', () async {
      final m = _model(server.url);
      final future = downloader.download(m);
      final live = downloader.progressOf(m.id)!;
      final seen = <int>[];
      final sub = live.stream.listen((p) => seen.add(p.receivedBytes));
      await future;
      await sub.cancel();
      expect(seen.last, _bytes.length);
      expect(seen, orderedEquals([...seen]..sort()));
      expect(seen.length, lessThan(10), reason: 'one update per MiB');
      expect(downloader.progressOf(m.id), isNull);
    });

    test('starts from the bytes already on disk', () async {
      await partOf(2000000);
      final m = _model(server.url);
      final future = downloader.download(m);
      // Synchronously, the moment it is asked for: no 0% flash.
      expect(downloader.progressOf(m.id)!.value.receivedBytes, 2000000);
      final seen = <int>[];
      final sub = downloader
          .progressOf(m.id)!
          .stream
          .listen((p) => seen.add(p.receivedBytes));
      await future;
      await sub.cancel();
      expect(seen.every((b) => b >= 2000000), isTrue, reason: '$seen');
    });
  });

  group('sharing and cancelling', () {
    setUp(() => server.chunkDelay = const Duration(milliseconds: 20));

    test('two callers share one transfer', () async {
      final m = _model(server.url);
      final files = await Future.wait([
        downloader.download(m),
        downloader.download(m),
      ]);
      expect(files[0].path, files[1].path);
      expect(server.requests, hasLength(1));
    });

    test('cancelling keeps the bytes received so far', () async {
      final m = _model(server.url);
      final token = CancelToken();
      final future = downloader.download(m, cancel: token);
      await downloader
          .progressOf(m.id)!
          .stream
          .firstWhere((p) => p.receivedBytes >= 1 << 20);
      token.cancel();
      await expectLater(future, throwsA(isA<DownloadCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await store.partLength(m.id), greaterThan(0));
      expect(await store.isInstalled(m), isFalse);
    });

    test('one caller cancelling does not stop the other', () async {
      final m = _model(server.url);
      final token = CancelToken();
      final cancelled = downloader.download(m, cancel: token);
      final kept = downloader.download(m);
      token.cancel();
      await expectLater(cancelled, throwsA(isA<DownloadCancelledException>()));
      expect(await (await kept).readAsBytes(), _bytes);
      expect(server.requests, hasLength(1));
    });

    test('a new request after a cancel resumes, never overlaps', () async {
      final m = _model(server.url);
      final token = CancelToken();
      final first = downloader.download(m, cancel: token);
      await downloader
          .progressOf(m.id)!
          .stream
          .firstWhere((p) => p.receivedBytes >= 1 << 20);
      token.cancel();
      // Asked for after the cancel has landed. (One asked for in the same
      // tick joins the transfer before it stops, which keeps it going.)
      await expectLater(first, throwsA(isA<DownloadCancelledException>()));
      final second = downloader.download(m);
      expect(await (await second).readAsBytes(), _bytes);
      expect(server.requests, hasLength(2));
      expect(server.requests.last.headers.value('range'), isNotNull);
    });

    test(
      'a token cancelled before the download starts sends nothing',
      () async {
        final token = CancelToken()..cancel();
        await expectLater(
          downloader.download(_model(server.url), cancel: token),
          throwsA(isA<DownloadCancelledException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(server.requests, isEmpty);
      },
    );
  });
}
