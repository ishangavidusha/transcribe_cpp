// An example app for transcribe_cpp: choose a model, download it, and
// dictate. Everything runs on the phone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

import 'background.dart';
import 'models.dart';
import 'models_page.dart';
import 'screen.dart';

void main() {
  // Before anything loads a model: the engine otherwise logs every backend
  // it registers.
  NativeLog.quiet();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorSchemeSeed: const Color(0xFF4F46E5),
    brightness: brightness,
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'transcribe_cpp',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const DictationPage(),
  );
}

class DictationPage extends StatefulWidget {
  const DictationPage({super.key});

  @override
  State<DictationPage> createState() => _DictationPageState();
}

class _DictationPageState extends State<DictationPage> {
  ModelManager? _models;
  ModelId? _choice;
  StreamSubscription<Object?>? _downloads;

  TranscribeSession? _session;
  ModelId? _sessionModel;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Finished sentences, one paragraph per pause.
  final _paragraphs = <String>[];

  /// Whether the last utterance was cut off mid-speech, so the next one
  /// carries on the same paragraph.
  var _continues = false;

  final _scroll = ScrollController();
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final models = await ModelManager.open();
    final saved = await ModelChoice.load();
    if (!mounted) return;
    _downloads = models.installed.stream.listen(
      (all) =>
          Screen.keepOn('download', all.containsValue(ModelStatus.downloading)),
    );
    setState(() {
      _models = models;
      _choice = saved != null && models.catalog[saved] != null
          ? saved
          : recommended.first.id;
    });
  }

  @override
  void dispose() {
    _downloads?.cancel();
    _closeSession();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _closeSession() async {
    final session = _session;
    _session = null;
    _sessionModel = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await session?.dispose();
  }

  bool get _listening => switch (_session?.state.value) {
    SessionState.starting ||
    SessionState.listening ||
    SessionState.finishing => true,
    _ => false,
  };

  Future<TranscribeSession> _open(ModelId id) async {
    if (_session case final session? when _sessionModel == id) return session;
    await _closeSession();
    final installed = await _models!.ensure(id);
    final session = await TranscribeSession.open(installed);
    _session = session;
    _sessionModel = id;
    _subscriptions.addAll([
      // The app bar and model card change with it.
      session.state.stream.listen((_) {
        setState(() {});
        Screen.keepOn('listening', _listening);
      }),
      session.utterances.listen((r) {
        if (r.isFinal) _addSentence(r);
      }, onError: (Object e) => setState(() => _error = 'Decoding failed: $e')),
      session.capture.stream.listen((status) {
        if (status.state == CaptureState.failed) {
          setState(() => _error = 'Microphone stopped: ${status.message}');
        }
      }),
    ]);
    return session;
  }

  void _addSentence(UtteranceResult result) {
    final text = result.text.trim();
    if (text.isEmpty) return;
    setState(() {
      if (_continues && _paragraphs.isNotEmpty) {
        _paragraphs.last = '${_paragraphs.last} $text';
      } else {
        _paragraphs.add(text);
      }
      _continues = result.utterance.truncated;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _start() async {
    final id = _choice;
    if (id == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await _open(id);
      setState(() => _loading = false);
      await session.start();
      await BackgroundListening.begin();
    } on StateError catch (e) {
      setState(
        () => _error = '${e.message}\nAllow the microphone in Settings.',
      );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _stop() async {
    await _session?.stop();
    await BackgroundListening.end();
    _continues = false;
  }

  Future<void> _download() async {
    final id = _choice;
    if (id == null) return;
    setState(() => _error = null);
    try {
      await _models!.ensure(id);
    } on DownloadCancelledException {
      // Cancelled from the models page.
    } catch (e) {
      setState(() => _error = 'Download failed: $e');
    }
  }

  Future<void> _chooseModel() async {
    final models = _models;
    if (models == null) return;
    final chosen = await Navigator.of(context).push<ModelId>(
      MaterialPageRoute(
        builder: (_) => ModelsPage(models: models, selected: _choice),
      ),
    );
    if (chosen == null || chosen == _choice) return;
    await _closeSession();
    await ModelChoice.save(chosen);
    setState(() {
      _choice = chosen;
      _error = null;
    });
  }

  String get _text => _paragraphs.join('\n\n');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Transcript copied')));
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final choice = _choice;
    if (models == null || choice == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final descriptor = models.catalog[choice]!;
    final session = _session;

    return Scaffold(
      appBar: AppBar(
        title: const Text('transcribe_cpp'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _paragraphs.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: _paragraphs.isEmpty || _listening
                ? null
                : () => setState(_paragraphs.clear),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: models.installed,
        builder: (context, installed, _) {
          final status = installed[choice] ?? ModelStatus.notInstalled;
          return SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: _ModelCard(
                    descriptor: descriptor,
                    status: status,
                    progress: models.progressOf(choice),
                    info: _sessionModel == choice ? session?.modelInfo : null,
                    onTap: _listening ? null : _chooseModel,
                  ),
                ),
                if (session != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _LiveBox(session: session),
                  ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _ErrorBanner(
                      message: error,
                      onClose: () => setState(() => _error = null),
                    ),
                  ),
                Expanded(
                  child: _paragraphs.isEmpty
                      ? _EmptyHint(installed: status == ModelStatus.installed)
                      : SelectionArea(
                          child: ListView.separated(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                            itemCount: _paragraphs.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 14),
                            itemBuilder: (context, i) => Text(
                              _paragraphs[i],
                              style: Theme.of(
                                context,
                              ).textTheme.bodyLarge?.copyWith(height: 1.45),
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16, top: 8),
                  child: Center(
                    child: status == ModelStatus.installed
                        ? _MicButton(
                            session: session,
                            loading: _loading,
                            onStart: _start,
                            onStop: _stop,
                          )
                        : FilledButton.icon(
                            onPressed: status == ModelStatus.downloading
                                ? null
                                : _download,
                            icon: const Icon(Icons.download),
                            label: Text(switch (status) {
                              ModelStatus.downloading => 'Downloading…',
                              ModelStatus.partial => 'Resume download',
                              _ =>
                                'Download ${formatBytes(descriptor.sizeBytes)}',
                            }),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Which model is in use, and the way to the models page.
class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.descriptor,
    required this.status,
    required this.progress,
    required this.info,
    required this.onTap,
  });

  final ModelDescriptor descriptor;
  final ModelStatus status;
  final Live<DownloadProgress>? progress;
  final ModelInfo? info;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = switch (status) {
      ModelStatus.installed => [
        formatBytes(descriptor.sizeBytes),
        if (info != null) info!.isGpu ? 'GPU' : 'CPU',
      ].join(' · '),
      ModelStatus.downloading => 'Downloading',
      ModelStatus.partial => 'Download paused',
      ModelStatus.notInstalled => 'Not downloaded yet',
    };
    return Card.filled(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${descriptor.displayName} · ${descriptor.quant}',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(detail, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  Text(
                    'Change',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: onTap == null
                          ? theme.disabledColor
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              if (status == ModelStatus.downloading && progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ValueListenableBuilder(
                    valueListenable: progress!,
                    builder: (context, p, _) => LinearProgressIndicator(
                      value: p.fraction,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sentence being spoken, above the finished ones. Its words settle as
/// they are heard, and it empties when the sentence is done and moves below.
class _LiveBox extends StatelessWidget {
  const _LiveBox({required this.session});

  final TranscribeSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: session.state,
      builder: (context, state, _) {
        if (state != SessionState.listening &&
            state != SessionState.finishing) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder(
          valueListenable: session.capture,
          builder: (context, capture, _) => ValueListenableBuilder(
            valueListenable: session.text,
            builder: (context, text, _) {
              final paused = capture.state != CaptureState.running;
              final label = switch (capture.state) {
                CaptureState.interrupted =>
                  'Paused${capture.message == null ? '' : ': ${capture.message}'}',
                CaptureState.recovering => 'Reconnecting the microphone',
                CaptureState.starting => 'Starting',
                _ => text.interim.isEmpty ? 'Listening' : 'Live',
              };
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                constraints: const BoxConstraints(minHeight: 72),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: paused
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Dot(active: !paused && text.interim.isNotEmpty),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      text.interim,
                      maxLines: 3,
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.outline,
    ),
  );
}

/// Start and stop, with a halo that follows the voice.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.session,
    required this.loading,
    required this.onStart,
    required this.onStop,
  });

  final TranscribeSession? session;
  final bool loading;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    if (session == null || loading) {
      return _button(context, listening: false, busy: loading, level: 0);
    }
    return ValueListenableBuilder(
      valueListenable: session.state,
      builder: (context, state, _) => ValueListenableBuilder(
        valueListenable: session.level,
        builder: (context, level, _) => _button(
          context,
          listening: state == SessionState.listening,
          busy:
              state == SessionState.starting || state == SessionState.finishing,
          level: state == SessionState.listening ? level.probability : 0,
        ),
      ),
    );
  }

  Widget _button(
    BuildContext context, {
    required bool listening,
    required bool busy,
    required double level,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = listening ? scheme.error : scheme.primary;
    return SizedBox(
      width: 112,
      height: 112,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 76 + 36 * level.clamp(0.0, 1.0),
            height: 76 + 36 * level.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.18),
            ),
          ),
          SizedBox(
            width: 72,
            height: 72,
            child: FilledButton(
              onPressed: busy ? null : (listening ? onStop : onStart),
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                backgroundColor: color,
                foregroundColor: listening ? scheme.onError : scheme.onPrimary,
              ),
              child: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Icon(listening ? Icons.stop_rounded : Icons.mic, size: 32),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.installed});

  final bool installed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          installed
              ? 'Tap the microphone and start talking.\n'
                    'Everything stays on this phone.'
              : 'Download the model to get started.\n'
                    'After that, no network is needed.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}
