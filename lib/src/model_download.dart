import 'dart:async';
import 'dart:io';

import 'catalog.dart';
import 'live.dart';
import 'model_store.dart';

/// How much of a model has arrived. State, not an event: a progress bar that
/// subscribes late should draw where the download is, not wait for the next
/// chunk.
final class DownloadProgress {
  const DownloadProgress(this.id, this.receivedBytes, this.totalBytes);

  final ModelId id;

  /// Bytes on disk for this model, including any from an earlier attempt
  /// that this one resumed.
  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 0 : receivedBytes / totalBytes;

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.id == id &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes;

  @override
  int get hashCode => Object.hash(id, receivedBytes, totalBytes);

  @override
  String toString() =>
      'DownloadProgress(${id.value}, $receivedBytes/$totalBytes)';
}

/// Lets one caller stop waiting for a download.
///
/// A download shared by several callers keeps going until all of them have
/// cancelled: a picker the user backs out of must not cancel the preload that
/// asked for the same model.
final class CancelToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<void> get _whenCancelled => _cancelled.future;
}

/// This caller cancelled. Bytes already received are kept for resuming.
final class DownloadCancelledException implements Exception {
  DownloadCancelledException(this.id);

  final ModelId id;

  @override
  String toString() => 'DownloadCancelledException(${id.value})';
}

/// The transfer failed. Bytes already received are kept unless [message]
/// says otherwise, so trying again resumes rather than restarts.
final class ModelDownloadException implements Exception {
  ModelDownloadException(this.id, this.message, {this.statusCode});

  final ModelId id;
  final String message;

  /// The HTTP status, when the server answered with an error.
  final int? statusCode;

  @override
  String toString() => 'ModelDownloadException(${id.value}): $message';
}

/// Fetches model files into a [ModelStore], resuming where a previous
/// attempt stopped.
///
/// Foreground only: a download lives as long as the app does. Resume is what
/// makes that acceptable, since reopening the app costs only the bytes that
/// were missing.
final class ModelDownloader {
  ModelDownloader(
    this.store, {
    HttpClient Function()? httpClient,
    this.idleTimeout = const Duration(seconds: 30),
  }) : _newClient = httpClient ?? HttpClient.new;

  final ModelStore store;
  final HttpClient Function() _newClient;

  /// How long the connection may stay silent before the download fails. A
  /// phone that loses signal mid-transfer otherwise waits on a dead socket
  /// with no error to show.
  final Duration idleTimeout;

  final _jobs = <ModelId, _Job>{};

  /// Progress of [id]'s download, or null when none is running.
  Live<DownloadProgress>? progressOf(ModelId id) => _jobs[id]?.progress.live;

  /// Downloads and installs [model], returning the installed file.
  ///
  /// Returns at once if it is already installed. A caller asking for a model
  /// that is already downloading joins that download instead of starting a
  /// second one into the same `.part`.
  Future<File> download(ModelDescriptor model, {CancelToken? cancel}) {
    var job = _jobs[model.id];
    if (job == null || job.aborted) {
      // A cancelled job may still be closing its file. The next one starts
      // after it has, so two transfers never write the same part.
      final previous = job?.settled ?? Future<void>.value();
      final next = job = _Job(model, store, _newClient, idleTimeout, previous);
      _jobs[model.id] = next;
      unawaited(
        next.settled.whenComplete(() {
          if (_jobs[model.id] == next) _jobs.remove(model.id);
          next.progress.close();
        }),
      );
    }
    return job.join(cancel);
  }
}

/// One transfer of one model, shared by every caller waiting for it.
final class _Job {
  _Job(
    this.model,
    this.store,
    this._newClient,
    this.idleTimeout,
    Future<void> previous,
  ) : progress = LiveController(
        // Starts at the bytes already on disk, so a bar drawn the moment a
        // resumed download is requested does not flash 0%.
        DownloadProgress(
          model.id,
          store.partLengthSync(model.id).clamp(0, model.sizeBytes),
          model.sizeBytes,
        ),
      ) {
    result = _run(previous);
    settled = result.then<void>((_) {}, onError: (Object _) {});
  }

  final ModelDescriptor model;
  final ModelStore store;
  final HttpClient Function() _newClient;
  final Duration idleTimeout;
  final LiveController<DownloadProgress> progress;

  late final Future<File> result;

  /// [result], minus its error: completes once the transfer has stopped
  /// touching the file, however it ended.
  late final Future<void> settled;

  final _abort = Completer<void>();
  var _waiters = 0;

  bool get aborted => _abort.isCompleted;

  Future<File> join(CancelToken? cancel) {
    _waiters++;
    final mine = Completer<File>();
    result.then(
      (f) {
        if (!mine.isCompleted) mine.complete(f);
      },
      onError: (Object e, StackTrace s) {
        if (!mine.isCompleted) mine.completeError(e, s);
      },
    );
    cancel?._whenCancelled.then((_) {
      if (mine.isCompleted) return;
      mine.completeError(DownloadCancelledException(model.id));
      if (--_waiters == 0 && !_abort.isCompleted) _abort.complete();
    });
    return mine.future;
  }

  Future<File> _run(Future<void> previous) async {
    await previous;
    // Every caller may have cancelled while the previous job was closing.
    if (aborted) throw DownloadCancelledException(model.id);
    if (await store.isInstalled(model)) {
      progress.value = DownloadProgress(
        model.id,
        model.sizeBytes,
        model.sizeBytes,
      );
      return store.fileOf(model.id);
    }
    var have = await store.partLength(model.id);
    if (have > model.sizeBytes) {
      await store.discardPart(model.id);
      have = 0;
    }
    progress.value = DownloadProgress(model.id, have, model.sizeBytes);
    if (have < model.sizeBytes) {
      await store.checkSpace(model);
      if (aborted) throw DownloadCancelledException(model.id);
      try {
        have = await _fetch(have, retryFromZero: true);
      } on IOException catch (e) {
        // Sockets, TLS, a connection dropped mid-body: one type for callers,
        // who can only retry, and a retry resumes.
        if (aborted) throw DownloadCancelledException(model.id);
        throw ModelDownloadException(model.id, 'connection failed: $e');
      } catch (_) {
        if (aborted) throw DownloadCancelledException(model.id);
        rethrow;
      }
    }
    if (have < model.sizeBytes) {
      throw ModelDownloadException(
        model.id,
        'connection closed after $have of ${model.sizeBytes} bytes',
      );
    }
    return store.commit(model);
  }

  /// Transfers from byte [from] to the end, returning the part's length.
  Future<int> _fetch(int from, {required bool retryFromZero}) async {
    final client = _newClient()..connectionTimeout = idleTimeout;
    // Closing the client is the one abort that works in every phase:
    // connecting, waiting for headers, or mid-body.
    final onAbort = _abort.future.then((_) => client.close(force: true));
    try {
      final response = await _request(client, from);
      final status = response.statusCode;

      if (status == HttpStatus.requestedRangeNotSatisfiable && retryFromZero) {
        // The part no longer matches what the server has. Start over once.
        await response.drain<void>();
        await store.discardPart(model.id);
        return _fetch(0, retryFromZero: false);
      }
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await response.drain<void>().catchError((_) {});
        throw _statusError(status);
      }

      var start = from;
      if (status == HttpStatus.ok) {
        // The server ignored the range and is sending the whole file.
        start = 0;
        final length = response.contentLength;
        if (length != -1 && length != model.sizeBytes) {
          throw ModelDownloadException(
            model.id,
            'server sent $length bytes, expected ${model.sizeBytes}',
          );
        }
      } else if (!_rangeStartsAt(response, from)) {
        throw ModelDownloadException(
          model.id,
          'server resumed at the wrong offset '
          '(${response.headers.value(HttpHeaders.contentRangeHeader)})',
        );
      }

      progress.value = DownloadProgress(model.id, start, model.sizeBytes);
      return await store.writePart(
        model,
        _watch(response, start),
        append: start > 0,
      );
    } finally {
      client.close(force: true);
      onAbort.ignore();
    }
  }

  /// Sends the request, following redirects by hand. Hugging Face answers
  /// with a redirect to a CDN on another host. dart:io's own redirects drop
  /// Authorization and cookies across domains but forward every other header,
  /// and forward all of them to subdomains; a token in, say, an `X-Api-Key`
  /// header would travel with the redirect. Here an app's headers go only to
  /// the host it named.
  Future<HttpClientResponse> _request(HttpClient client, int from) async {
    var url = model.url;
    var headers = model.headers;
    for (var hops = 0; ; hops++) {
      if (url.scheme != 'https' && url.scheme != 'http') {
        throw ModelDownloadException(model.id, 'unsupported URL $url');
      }
      final request = await client.getUrl(url);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (from > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      }
      final response = await request.close();
      if (!response.isRedirect) return response;

      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || hops == 5) {
        throw ModelDownloadException(model.id, 'too many redirects from $url');
      }
      final next = url.resolve(location);
      if (next.host != url.host) headers = const {};
      url = next;
    }
  }

  bool _rangeStartsAt(HttpClientResponse response, int from) {
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = RegExp(r'^bytes (\d+)-').firstMatch(range ?? '');
    return match != null && int.parse(match.group(1)!) == from;
  }

  ModelDownloadException _statusError(int status) =>
      ModelDownloadException(model.id, switch (status) {
        HttpStatus.unauthorized || HttpStatus.forbidden =>
          'access denied (HTTP $status): the repository may need a token in '
              'ModelDescriptor.headers',
        HttpStatus.notFound => 'not found (HTTP 404) at ${model.url}',
        _ => 'HTTP $status',
      }, statusCode: status);

  /// The response body, counted into [progress], failing on silence and
  /// ending at once on abort.
  Stream<List<int>> _watch(HttpClientResponse response, int start) {
    var received = start;
    var reported = start;
    late final StreamSubscription<List<int>> sub;
    final out = StreamController<List<int>>(
      onPause: () => sub.pause(),
      onResume: () => sub.resume(),
      onCancel: () => sub.cancel(),
    );
    void fail(Object error) {
      sub.cancel();
      if (out.isClosed) return;
      out.addError(error);
      out.close();
    }

    sub = response
        .timeout(
          idleTimeout,
          onTimeout: (_) => fail(
            ModelDownloadException(
              model.id,
              'no data for ${idleTimeout.inSeconds} s',
            ),
          ),
        )
        .listen(
          (chunk) {
            received += chunk.length;
            out.add(chunk);
            // One update per MiB: a 1 GB model would otherwise publish about
            // 15,000 values, each a rebuild of whatever draws the bar.
            if (received - reported >= 1 << 20 || received == model.sizeBytes) {
              reported = received;
              progress.value = DownloadProgress(
                model.id,
                received,
                model.sizeBytes,
              );
            }
          },
          onError: (Object e) => fail(e),
          onDone: () {
            progress.value = DownloadProgress(
              model.id,
              received,
              model.sizeBytes,
            );
            out.close();
          },
          cancelOnError: true,
        );
    _abort.future.then((_) => fail(DownloadCancelledException(model.id)));
    return out.stream;
  }
}
