import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// Console log for a live dictation session, written to be pasted back.
///
/// The point of this file is that tuning this pipeline is not something the
/// numbers alone can settle — whether the hangover is too short or the gain too
/// timid is a judgement about how it felt to talk to. What a log can do is make
/// that judgement attributable: every run prints the exact configuration that
/// produced it, then one line per utterance with the measurements that
/// configuration is supposed to move, then a transcript block clean enough to
/// diff against a reference.
///
/// So the format is chosen for reading in a diff, not for machine parsing:
/// aligned columns, absolute units, no framework noise, and a summary that
/// answers the three questions worth asking after a session — did the
/// endpointer cut in the right places, did live text keep up, and was the audio
/// at a level the models could work with.
class SessionLog {
  SessionLog({
    required this.model,
    required this.info,
    required this.endpointer,
    required this.normalizer,
    required this.provisionalInterval,
    required this.stableAgreement,
    this.label,
    this.replay = false,
    this.audioDuration,
  });

  final String model;
  final ModelInfo? info;
  final EndpointerConfig endpointer;
  final NormalizerConfig? normalizer;
  final Duration provisionalInterval;
  final int stableAgreement;

  /// Names the run when several are compared in one go.
  final String? label;

  /// Length of the replayed clip.
  ///
  /// Needed because a replay's wall clock measures how fast this machine got
  /// through the audio, not how much audio there was — reporting speech as a
  /// percentage of the former would say more about the decoder's speed than
  /// about the recording.
  final Duration? audioDuration;

  /// Replay of a recording rather than a live session.
  ///
  /// Suppresses the live-text columns instead of printing zeros: replay feeds
  /// audio as fast as it can and turns provisional decoding off, so a `prov`
  /// count there would describe this machine's scheduler rather than the
  /// pipeline. Segmentation, gain and transcripts stay exact.
  final bool replay;

  final _clock = Stopwatch();
  final _finals = <String>[];

  var _utterances = 0;
  var _truncated = 0;
  var _empty = 0;
  var _speech = Duration.zero;
  var _decodeTotal = Duration.zero;
  var _decodeWorst = Duration.zero;
  var _words = 0;
  var _dropouts = 0;
  var _lost = Duration.zero;

  /// Bursts the endpointer filtered as transients. Reported because the filter
  /// is a guess, and this is the only place a session says how often it fired
  /// and on what — the numbers you would need before moving minSpeech.
  var _discarded = 0;
  var _discardedAudio = Duration.zero;
  var _discardedLongest = Duration.zero;
  var _discardedPeak = 0.0;

  /// Provisional decodes seen for the utterance currently in progress, and how
  /// many words the live box was showing when it ended.
  var _provisional = 0;
  var _liveWords = 0;
  var _provisionalTotal = 0;

  /// Input level, before gain, over the utterance in progress. This is the
  /// "how loud were you actually speaking" measurement, and it is the one axis
  /// a session log could not previously report at all.
  var _inRms = 0.0;
  var _inCount = 0;
  var _inLoudest = 0.0;
  var _sessionInSum = 0.0;
  var _sessionInCount = 0;

  var _gainMin = double.infinity;
  var _gainMax = 0.0;
  var _gainSum = 0.0;

  /// Gain in force at the last level update, which is what an utterance row
  /// reports — the number that explains the level the model actually saw.
  ///
  /// Read from the level stream rather than passed in by the caller. It used
  /// to be a parameter, and the replay loop passed the *live* capture's level,
  /// which is reset to 1.0x and never updated during a replay: every replay
  /// row in session_004 printed `gain=1.0x` while its own in/out levels imply
  /// a median of 4.3x. The summary line was right the whole time, because it
  /// came from here. Both paths now read the same source and cannot disagree.
  var _gainLatest = 1.0;
  var _noise = 0.0;
  var _levels = 0;
  var _voicedWindows = 0;

  /// The whole transcript, as one block.
  String get transcript => _finals.join(' ');

  void start() {
    _clock
      ..reset()
      ..start();
    final gpu = info == null
        ? 'unknown'
        : (info!.isGpu
              ? 'GPU/${info!.backend}'
              : 'CPU-FALLBACK/${info!.backend}');
    _line('');
    _line(
      replay
          ? '======== replay${label == null ? '' : ': $label'} ========'
          : '======== session start${label == null ? '' : ': $label'} ========',
    );
    _line('model      $model  [$gpu]');
    _line(
      'endpointer speech=${endpointer.speechThreshold} '
      'silence=${endpointer.silenceThreshold} '
      'minSpeech=${_ms(endpointer.minSpeechDuration)} '
      'reattach=${_ms(endpointer.reattachWithin)} '
      'hangover=${_ms(endpointer.hangover)} '
      'preRoll=${_ms(endpointer.preRoll)} '
      'postRoll=${_ms(endpointer.postRoll)} '
      'max=${_s(endpointer.maxUtterance)}',
    );
    _line(
      normalizer == null
          ? 'normalizer OFF'
          : 'normalizer target=${normalizer!.targetLevel} '
                'gain=${normalizer!.minGain}-${normalizer!.maxGain}x '
                'peakCeiling=${normalizer!.peakCeiling} '
                'noiseCeiling=${normalizer!.noiseCeiling} '
                'margin=${normalizer!.signalMargin} '
                'window=${_s(normalizer!.noiseWindow)}',
    );
    if (!replay) {
      _line(
        'live       provisional=${_ms(provisionalInterval)} '
        'agreement=$stableAgreement',
      );
    }
    _line('-------------------------------');
  }

  /// One line per finished utterance. This is the row that carries the
  /// evidence: where it was cut, how loud it was, and how far behind the live
  /// text had fallen by the time it closed.
  void utterance(UtteranceResult r) {
    final u = r.utterance;
    final text = r.text.trim();
    _utterances++;
    if (u.truncated) _truncated++;
    if (text.isEmpty) _empty++;
    _speech += u.speechEnd - u.speechStart;
    _decodeTotal += r.decode;
    if (r.decode > _decodeWorst) _decodeWorst = r.decode;

    final words = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
    _words += words;
    if (text.isNotEmpty) _finals.add(text);

    final peak = _peak(u.audio);
    final rms = _rms(u.audio);
    final inDb = _inCount == 0 ? null : _dbfs(_inRms / _inCount);
    // Guarded rather than printed as infinity: a decode that rounds to zero
    // means the clock is too coarse to say, not that it was infinitely fast.
    final rtf = r.decode.inMicroseconds == 0
        ? null
        : u.duration.inMicroseconds / r.decode.inMicroseconds;

    // Snapshots that *should* have fired, against those that did. The gap is
    // decode failing to keep up with the interval, which is the only way live
    // text degrades — it is designed to drop rather than queue.
    final expected = provisionalInterval > Duration.zero
        ? u.duration.inMicroseconds ~/ provisionalInterval.inMicroseconds
        : 0;

    _line(
      '[${_pad(_utterances.toString(), 3)}] '
      '${_pad(_s(u.start), 6)}+${_pad(_s(u.duration), 5)} '
      'in=${_pad(inDb == null ? '-' : '${inDb.toStringAsFixed(1)}dB', 8)} '
      'gain=${_pad('${_gainLatest.toStringAsFixed(1)}x', 6)} '
      'out=${_pad('${_dbfs(rms).toStringAsFixed(1)}dB', 8)} '
      'peak=${_pad(peak.toStringAsFixed(2), 5)} '
      'decode=${_pad('${r.decode.inMilliseconds}ms', 6)} '
      'rtf=${_pad(rtf == null ? '-' : '${rtf.toStringAsFixed(1)}x', 6)} '
      '${replay ? '' : 'prov=$_provisional/$expected live=$_liveWords/${words}w'}'
      '${u.truncated ? ' TRUNCATED' : ''}'
      '${text.isEmpty ? ' EMPTY' : ''}',
    );
    if (text.isNotEmpty) _line('      "$text"');

    _provisionalTotal += _provisional;
    _provisional = 0;
    _liveWords = 0;
    _inRms = 0;
    _inCount = 0;
  }

  void provisional(UtteranceResult r) {
    _provisional++;
    final stable = r.stableText.trim();
    _liveWords = stable.isEmpty ? 0 : stable.split(RegExp(r'\s+')).length;
  }

  void level(LiveLevel l) {
    _levels++;
    // Speech blocks only. Averaging in the silences would report the room, and
    // the room is already reported as the noise floor.
    if (l.probability >= endpointer.speechThreshold && l.inputRms > 0) {
      _inRms += l.inputRms;
      _inCount++;
      if (l.inputRms > _inLoudest) _inLoudest = l.inputRms;
      _sessionInSum += l.inputRms;
      _sessionInCount++;
    }
    _gainLatest = l.gain;
    _gainSum += l.gain;
    if (l.gain < _gainMin) _gainMin = l.gain;
    if (l.gain > _gainMax) _gainMax = l.gain;
    if (l.probability >= endpointer.speechThreshold) _voicedWindows++;
    _noise = l.noise;
  }

  /// A burst the duration floor threw away.
  ///
  /// Printed inline rather than only counted: what makes one of these
  /// interesting is *where* it sits. One next to a decoded utterance in the
  /// transcript block is a candidate lost word; one in the middle of a silent
  /// stretch is the filter doing its job.
  void discarded(SpeechDiscarded d) {
    _discarded++;
    _discardedAudio += d.duration;
    if (d.duration > _discardedLongest) _discardedLongest = d.duration;
    if (d.peakProbability > _discardedPeak) _discardedPeak = d.peakProbability;
    _line(
      '[--] discarded ${_pad('${d.duration.inMilliseconds}ms', 6)} '
      'at ${_pad(_s(d.speechStart), 6)} '
      'peak=${d.peakProbability.toStringAsFixed(2)} — below minSpeech',
    );
  }

  void dropout(Dropout d) {
    _dropouts++;
    _lost += d.duration;
    _line(
      '[!!] dropout ${d.duration.inMilliseconds}ms — transcript has a hole',
    );
  }

  void captureState(CaptureStatus s) {
    if (s.state == CaptureState.running || s.state == CaptureState.idle) return;
    _line(
      '[!!] capture ${s.state.name}${s.message == null ? '' : ' — ${s.message}'}',
    );
  }

  void error(Object e) => _line('[!!] $e');

  void stop() {
    _clock.stop();
    final wall = audioDuration ?? _clock.elapsed;
    final voiced = _levels == 0 ? 0.0 : _voicedWindows / _levels;

    _line('-------------------------------');
    _line(
      '${replay ? 'audio     ' : 'captured  '} ${_s(wall)} · speech ${_s(_speech)} '
      '(${_percent(_speech.inMicroseconds, wall.inMicroseconds)}) '
      '· VAD voiced ${(voiced * 100).round()}% of windows',
    );
    _line(
      'utterances $_utterances'
      '${_truncated > 0 ? ' ($_truncated truncated)' : ''}'
      '${_empty > 0 ? ' ($_empty decoded empty)' : ''}'
      ' · $_words words'
      '${_utterances == 0 ? '' : ' · avg ${(_words / _utterances).toStringAsFixed(1)} words, '
                '${_s(Duration(microseconds: _speech.inMicroseconds ~/ _utterances))} each'}',
    );
    if (!replay) {
      _line(
        'decode     total ${_s(_decodeTotal)} · '
        'avg ${_utterances == 0 ? 0 : _decodeTotal.inMilliseconds ~/ _utterances}ms · '
        'worst ${_decodeWorst.inMilliseconds}ms · '
        'duty ${_percent(_decodeTotal.inMicroseconds, wall.inMicroseconds)} '
        '($_provisionalTotal provisional decodes)',
      );
    } else {
      _line(
        'decode     total ${_s(_decodeTotal)} · '
        'avg ${_utterances == 0 ? 0 : _decodeTotal.inMilliseconds ~/ _utterances}ms · '
        'worst ${_decodeWorst.inMilliseconds}ms',
      );
    }
    final gain = _levels == 0
        ? 'n/a'
        : '${_gainMin.toStringAsFixed(1)}-${_gainMax.toStringAsFixed(1)}x '
              '(avg ${(_gainSum / _levels).toStringAsFixed(1)}x)';
    _line(
      'input      speech ${_sessionInCount == 0 ? 'n/a' : '${_dbfs(_sessionInSum / _sessionInCount).toStringAsFixed(1)}dBFS avg, '
                '${_dbfs(_inLoudest).toStringAsFixed(1)}dBFS loudest'} · '
      'room ${_noise > 0 ? '${_dbfs(_noise).toStringAsFixed(1)}dBFS' : 'n/a'}',
    );
    _line(
      'audio      gain $gain · '
      'dropouts $_dropouts (${_lost.inMilliseconds}ms lost)',
    );
    if (_discarded > 0) {
      // The tuning row for minSpeech. If the longest discard is crowding the
      // floor and the peaks are high, these were probably words; if they are
      // one or two windows each, they were probably not.
      _line(
        'discarded  $_discarded bursts · '
        '${_discardedAudio.inMilliseconds}ms · '
        'longest ${_discardedLongest.inMilliseconds}ms of '
        '${_ms(endpointer.minSpeechDuration)} · '
        'peak ${_discardedPeak.toStringAsFixed(2)}',
      );
    }
    _line('');
    _line('======== transcript ========');
    // Chunked. A single long line is silently cut short on its way through the
    // device log — the first session lost two thirds of its transcript that
    // way, which is the one thing in here that cannot be reconstructed from
    // anything else.
    for (final chunk in _wrap(transcript, 320)) {
      _line(chunk);
    }
    _line(
      replay ? '======== replay end ========' : '======== session end ========',
    );
    _line('');
  }

  static void _line(String s) => debugPrint(s);

  /// Pads to [width], but never to nothing.
  ///
  /// A value that already fills the column would otherwise butt straight up
  /// against the next one — `114.1s+10.7s` once the session passes 100 s — and
  /// these rows are meant to be parsed as well as read.
  static String _pad(String s, int width) =>
      s.length >= width ? '$s ' : s.padRight(width);

  /// Level as dBFS. Floored rather than allowed to run to negative infinity,
  /// which formats badly and means the same thing as "silent".
  static double _dbfs(double rms) =>
      rms <= 1e-6 ? -120.0 : 20 * (math.log(rms) / math.ln10);

  /// Splits on word boundaries so a chunk never cuts a word in half — the
  /// transcript is going to be diffed against a reference, and a split word
  /// would read as two recognition errors that never happened.
  static List<String> _wrap(String text, int width) {
    final out = <String>[];
    final buffer = StringBuffer();
    for (final word in text.split(' ')) {
      if (buffer.isNotEmpty && buffer.length + 1 + word.length > width) {
        out.add(buffer.toString());
        buffer.clear();
      }
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(word);
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out;
  }

  /// Clamped, because a session that was backgrounded or stopped instantly can
  /// otherwise report five-digit percentages that read as a measurement fault
  /// rather than a short run.
  static String _percent(int part, int whole) {
    if (whole <= 0) return '-';
    return '${math.min(100, (part / whole * 100).round())}%';
  }

  static String _ms(Duration d) => '${d.inMilliseconds}ms';
  static String _s(Duration d) =>
      '${(d.inMicroseconds / 1000000).toStringAsFixed(1)}s';

  static double _peak(Float32List x) {
    var peak = 0.0;
    for (final v in x) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    return peak;
  }

  static double _rms(Float32List x) {
    if (x.isEmpty) return 0;
    var sum = 0.0;
    for (final v in x) {
      sum += v * v;
    }
    return math.sqrt(sum / x.length);
  }
}
