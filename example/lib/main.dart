// Live dictation harness for the transcribe_cpp plugin.
//
// Deliberately one thing: start the microphone, run VAD-gated decoding with
// live provisional text, and print a log that says exactly which configuration
// produced what. The benchmark screens this app used to carry answered
// questions that are now settled — batch beats streaming on this hardware, and
// parakeet beats moonshine on speed — so they were removed rather than left to
// rot alongside the path actually being developed.
//
// The console is the output that matters. See session_log.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

import 'session_log.dart';

void main() {
  // Before anything loads a model, per the engine's contract. Without it every
  // launch opens with a page of ggml backend registration and Metal buffer
  // allocations, which is the noise that makes a pasted log unreadable.
  NativeLog.quiet();
  runApp(const DictationApp());
}

class DictationApp extends StatelessWidget {
  const DictationApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'transcribe.cpp dictation',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
    ),
    home: const DictationPage(),
  );
}

/// Tuning knobs surfaced in the UI.
///
/// Only the ones a session can actually settle. Everything else stays at its
/// documented default, because a control that is never the reason a run went
/// badly is a control that makes runs harder to compare.
enum _Preset {
  // Spelled out rather than leaning on EndpointerConfig's default, so that a
  // change to the default cannot silently make two presets identical.
  eager('eager', EndpointerConfig(hangover: Duration(milliseconds: 250))),
  balanced('balanced', EndpointerConfig(hangover: Duration(milliseconds: 400))),
  patient('patient', EndpointerConfig(hangover: Duration(milliseconds: 700)));

  const _Preset(this.label, this.endpointer);
  final String label;
  final EndpointerConfig endpointer;
}

class DictationPage extends StatefulWidget {
  const DictationPage({super.key});

  @override
  State<DictationPage> createState() => _DictationPageState();
}

class _DictationPageState extends State<DictationPage> {
  // Ids from the bundled catalogue. Downloaded on first use, then kept.
  static const _models = <({String label, ModelId id, String note})>[
    (
      label: 'parakeet-tdt_ctc-110m',
      id: ModelId('parakeet-tdt_ctc-110m-Q4_K_M'),
      note: '90 MB Q4_K_M · 2.53% WER',
    ),
    (
      label: 'moonshine-streaming-tiny',
      id: ModelId('moonshine-streaming-tiny-Q8_0'),
      note: '50 MB Q8_0 · 4.52% WER',
    ),
  ];

  static const _provisionalInterval = Duration(milliseconds: 350);
  static const _stableAgreement = 2;

  int _selected = 0;
  _Preset _preset = _Preset.balanced;
  bool _normalize = true;

  ModelManager? _manager;
  TranscribeSession? _session;
  final _sessionSubscriptions = <StreamSubscription<Object?>>[];

  /// The log of the run in progress, live or replayed. The session's streams
  /// last as long as it does, so every run writes to whichever log is current.
  SessionLog? _log;
  String? _recording;
  String _compareStatus = '';

  String _transcript = '';
  String _provisional = '';
  CaptureStatus _capture = const CaptureStatus(CaptureState.idle);
  LiveLevel _level = LiveLevel.silent;
  bool _speaking = false;
  bool _listening = false;
  Duration _lost = Duration.zero;
  String _status = 'Idle';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // A recording outlives the process, so a comparison can be run against a
    // session captured before the last restart — which is usually exactly the
    // session worth looking at again.
    _findRecording();
    ModelManager.open().then((m) {
      if (mounted) setState(() => _manager = m);
    });
  }

  Future<void> _findRecording() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/session.wav');
    if (file.existsSync() && file.lengthSync() > 1024 && mounted) {
      setState(() => _recording = file.path);
    }
  }

  @override
  void dispose() {
    _closeSession();
    super.dispose();
  }

  Future<void> _closeSession() async {
    final session = _session;
    _session = null;
    for (final s in _sessionSubscriptions) {
      await s.cancel();
    }
    _sessionSubscriptions.clear();
    await session?.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _lost = Duration.zero;
    });
    try {
      final session = await _ensureLoaded();
      final normalizer = _normalize ? const NormalizerConfig() : null;
      final log = SessionLog(
        model: _models[_selected].label,
        info: session.modelInfo,
        endpointer: _preset.endpointer,
        normalizer: normalizer,
        provisionalInterval: _provisionalInterval,
        stableAgreement: _stableAgreement,
      );

      // Every session is recorded, so any run can be turned into a controlled
      // comparison afterwards. Cheap — float32 at 16 kHz is 3.7 MB a minute —
      // and the alternative is discovering after the fact that the interesting
      // session cannot be repeated.
      final dir = await getApplicationSupportDirectory();
      final recording = '${dir.path}/session.wav';

      setState(() => _status = 'Starting');
      _log = log;
      await session.start(
        endpointer: _preset.endpointer,
        normalizer: normalizer,
        provisionalInterval: _provisionalInterval,
        stableAgreement: _stableAgreement,
        recordTo: recording,
      );
      log.start();
      setState(() {
        _listening = true;
        _recording = recording;
        _status = 'Listening';
      });
    } catch (e) {
      _log = null;
      setState(() {
        _status = 'Idle';
        _error = '$e';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null || !_listening) return;
    setState(() {
      _busy = true;
      _status = 'Finishing';
    });
    await session.stop();
    // After stop, so the flushed final utterance is in the tally.
    _log?.stop();
    _log = null;
    setState(() {
      _listening = false;
      _speaking = false;
      _status = 'Stopped';
      _busy = false;
    });
  }

  /// Replays the last recording under each setting worth comparing.
  ///
  /// The reason this exists: a microphone hands you different audio every time,
  /// so two settings tried across two live sessions were measured on two
  /// different passages and the difference between them says nothing. Same
  /// bytes, every run, is the only way the comparison means anything.
  Future<void> _compare() async {
    final path = _recording;
    if (path == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _compareStatus = 'Loading recording';
    });
    try {
      final audio = Wav.read(path);
      final session = await _ensureLoaded();

      final matrix =
          <({String label, EndpointerConfig ep, NormalizerConfig? n})>[
            for (final p in _Preset.values)
              (label: p.label, ep: p.endpointer, n: const NormalizerConfig()),
            // Gain off, measured against the default preset.
            (
              label: 'balanced, no gain',
              ep: _Preset.balanced.endpointer,
              n: null,
            ),
          ];

      for (var i = 0; i < matrix.length; i++) {
        final run = matrix[i];
        setState(
          () => _compareStatus = '${i + 1}/${matrix.length}  ${run.label}',
        );
        final log = SessionLog(
          model: _models[_selected].label,
          info: session.modelInfo,
          endpointer: run.ep,
          normalizer: run.n,
          provisionalInterval: Duration.zero,
          stableAgreement: _stableAgreement,
          label: run.label,
          replay: true,
          audioDuration: Duration(
            microseconds: audio.length * 1000000 ~/ vadSampleRate,
          ),
        );
        _log = log;
        log.start();
        await session.replay(
          audio,
          endpointer: run.ep,
          normalizer: run.n,
          stableAgreement: _stableAgreement,
        );
        log.stop();
        _log = null;
      }
      setState(() => _compareStatus = 'Done — see the console');
    } catch (e) {
      _log = null;
      setState(() {
        _error = '$e';
        _compareStatus = '';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Downloads the selected model if needed, and opens a session on it once.
  Future<TranscribeSession> _ensureLoaded() async {
    if (_session case final session?) return session;
    final manager = _manager ??= await ModelManager.open();
    final id = _models[_selected].id;

    setState(() => _status = 'Preparing model');
    final installing = manager.ensure(id);
    final progress = manager.progressOf(id)?.stream.listen((p) {
      setState(
        () => _status = 'Downloading ${(p.fraction * 100).toStringAsFixed(0)}%',
      );
    });
    final InstalledModel installed;
    try {
      installed = await installing;
    } finally {
      await progress?.cancel();
    }

    setState(() => _status = 'Loading model');
    final session = await TranscribeSession.open(installed);
    _session = session;
    _sessionSubscriptions.addAll([
      session.utterances.listen(
        (r) => r.isFinal ? _log?.utterance(r) : _log?.provisional(r),
        onError: (Object e) {
          _log?.error(e);
          setState(() => _error = '$e');
        },
      ),
      session.text.stream.listen(
        (t) => setState(() {
          _transcript = t.settled;
          _provisional = t.interim;
        }),
      ),
      session.events.listen((e) {
        if (e is SpeechStarted) setState(() => _speaking = true);
        if (e is SpeechEnded) setState(() => _speaking = false);
        if (e is SpeechDiscarded) _log?.discarded(e);
      }),
      session.capture.stream.listen((s) {
        if (_listening) _log?.captureState(s);
        setState(() => _capture = s);
      }),
      session.level.stream.listen((l) {
        _log?.level(l);
        setState(() => _level = l);
      }),
      session.dropouts.listen((d) {
        _log?.dropout(d);
        setState(() => _lost += d.duration);
      }),
    ]);
    setState(() => _status = 'Idle');
    return session;
  }

  Future<void> _select(int index) async {
    if (index == _selected) return;
    setState(() {
      _selected = index;
      _status = 'Idle';
    });
    await _closeSession();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('transcribe.cpp')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: [
                for (var i = 0; i < _models.length; i++)
                  ButtonSegment(
                    value: i,
                    label: Text(
                      _models[i].label.split('-').first,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
              ],
              selected: {_selected},
              onSelectionChanged: (_busy || _listening)
                  ? null
                  : (s) => _select(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              _manager?.installed.value[_models[_selected].id] ==
                      ModelStatus.installed
                  ? _models[_selected].note
                  : '${_models[_selected].note} · downloads on first use',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<_Preset>(
                    segments: [
                      for (final p in _Preset.values)
                        ButtonSegment(
                          value: p,
                          label: Text(
                            p.label,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                    ],
                    selected: {_preset},
                    showSelectedIcon: false,
                    onSelectionChanged: (_busy || _listening)
                        ? null
                        : (s) => setState(() => _preset = s.first),
                  ),
                ),
                const SizedBox(width: 10),
                FilterChip(
                  label: const Text('gain'),
                  selected: _normalize,
                  onSelected: (_busy || _listening)
                      ? null
                      : (v) => setState(() => _normalize = v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'hangover ${_preset.endpointer.hangover.inMilliseconds}ms · '
              'provisional ${_provisionalInterval.inMilliseconds}ms · '
              'agreement $_stableAgreement',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : (_listening ? _stop : _start),
              style: FilledButton.styleFrom(
                backgroundColor: _listening
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                foregroundColor: _listening
                    ? theme.colorScheme.onError
                    : theme.colorScheme.onPrimary,
                minimumSize: const Size.fromHeight(52),
              ),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(
                _busy ? _status : (_listening ? 'Stop' : 'Start listening'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_busy || _listening || _recording == null)
                  ? null
                  : _compare,
              icon: const Icon(Icons.compare_arrows),
              label: Text(
                _recording == null
                    ? 'Compare settings (record a session first)'
                    : _compareStatus.isEmpty
                    ? 'Compare settings on the last recording'
                    : _compareStatus,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _LevelMeter(
                    level: _level.probability,
                    speaking: _speaking,
                  ),
                ),
                const SizedBox(width: 8),
                _Chip(
                  label: '${_level.gain.toStringAsFixed(1)}x',
                  tone: _level.gain > 1.2
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                ),
                if (_listening) ...[
                  const SizedBox(width: 8),
                  _Chip(
                    label: _capture.state.name,
                    tone: switch (_capture.state) {
                      CaptureState.running =>
                        theme.colorScheme.primaryContainer,
                      CaptureState.failed => theme.colorScheme.errorContainer,
                      _ => theme.colorScheme.tertiaryContainer,
                    },
                  ),
                ],
                if (_lost > Duration.zero) ...[
                  const SizedBox(width: 8),
                  _Chip(
                    label: 'lost ${_lost.inMilliseconds}ms',
                    tone: theme.colorScheme.errorContainer,
                  ),
                ],
              ],
            ),
            if (_session?.modelInfo case final info?) ...[
              const SizedBox(height: 8),
              Text(
                '${info.isGpu ? 'GPU' : 'CPU FALLBACK'} · ${info.backend} · '
                '${info.variant} · ${info.architecture}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: info.isGpu
                      ? theme.colorScheme.outline
                      : theme.colorScheme.error,
                ),
              ),
            ],
            if (_error case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_listening) ...[
              _LiveBox(text: _provisional),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: SingleChildScrollView(
                reverse: _listening,
                child: SelectableText(
                  _transcript,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where speech in progress shows up, above the settled transcript.
///
/// Separate from the transcript on purpose. The text in here is a decode of an
/// utterance that has not finished, so it grows as the sentence does and is
/// then replaced wholesale by the final decode. Interleaving that with settled
/// text would make the bottom of the transcript twitch; keeping it in its own
/// box means the transcript below only ever gains a finished sentence.
///
/// It shows the agreed prefix rather than the newest decode, so what appears
/// here extends and does not rewrite itself.
class _LiveBox extends StatelessWidget {
  const _LiveBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = text.isEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: empty
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: empty
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.secondary,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            empty ? 'listening' : 'live',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            empty ? '' : text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small status pill. The capture state is the thing to watch during a live
/// session — it is where interruptions and route changes show up.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: tone,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}

/// The VAD's raw probability, updated every ~60 ms.
///
/// Deliberately not the endpointer's `isSpeaking`: that reports *confirmed*
/// speech, so it turns on a quarter second late and off at the endpoint, which
/// makes it read "silence" while someone is plainly talking. The bar follows
/// the model directly; the dot shows what the endpointer has committed to.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.speaking});

  final double level;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: speaking
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: level.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                level >= 0.5
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
