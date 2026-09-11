import 'dart:math' as math;
import 'dart:typed_data';

import 'vad.dart';

/// Tuning for [AudioNormalizer].
///
/// The defaults are aimed at one failure: someone speaking quietly, or far from
/// the phone, whose speech the VAD scores below threshold and never opens an
/// utterance for. That is not a decoder problem — it is audio arriving at an
/// amplitude both models were undertrained on — so the fix belongs in front of
/// the VAD rather than in either model's thresholds.
class NormalizerConfig {
  const NormalizerConfig({
    this.targetLevel = 0.15,
    this.maxGain = 20.0,
    this.minGain = 0.25,
    this.noiseCeiling = 0.012,
    this.noiseWindow = const Duration(seconds: 2),
    this.attack = const Duration(milliseconds: 30),
    this.release = const Duration(milliseconds: 600),
    this.gainRise = const Duration(milliseconds: 300),
    this.gainFall = const Duration(milliseconds: 60),
    this.signalMargin = 4.0,
    this.peakCeiling = 0.7,
    this.limit = 0.97,
  });

  /// Envelope level the gain aims to put speech at.
  ///
  /// Not a peak: the follower is asymmetric (fast up, slow down) so it rides
  /// below the true peak, and how far below depends on crest factor — a sine
  /// reads about 0.92 of its peak, running speech far less. Measured on a real
  /// session, speech came back at a crest factor of 6.5, so a target set from
  /// sine tests drove every single utterance into the limiter.
  ///
  /// 0.15 puts speech around -23 dBFS RMS, which is where normal dictation
  /// already sits. [peakCeiling] is what actually guarantees the headroom; this
  /// only sets the average.
  final double targetLevel;

  /// Hard cap on boost, before the noise-aware cap below is applied.
  ///
  /// 20x is about +26 dB, enough to lift a quiet voice across a room to a
  /// normal level. Set generously on purpose: this is a backstop against
  /// pathological input, not the safety mechanism. [noiseCeiling] is the
  /// mechanism, and in any room with an audible floor it is what actually
  /// binds — which is the right way round, because it is the one that knows
  /// whether boosting can help.
  final double maxGain;

  /// Hard floor on gain, i.e. how far the stage may *attenuate*.
  ///
  /// Attenuating matters as much as boosting, and for the same reason. The
  /// point of this stage is to make the microphone's level stop reaching the
  /// models — but a boost-only stage lifts quiet input and leaves loud input
  /// alone, so level still arrives, just compressed at one end. Both directions
  /// means audio recorded across a room and audio recorded against the chin
  /// present identically, which is the only version of this that makes the
  /// level a solved problem rather than a smaller one.
  ///
  /// Attenuation is free in the way boosting is not: it cannot amplify noise,
  /// and it cannot clip. The floor exists only so one pathological transient
  /// cannot crush the speech behind it.
  final double minGain;

  /// How loud the noise floor is allowed to become *after* gain, as RMS.
  ///
  /// This is the whole safety property. Gain cannot improve signal-to-noise
  /// ratio, so amplifying a noisy room only lifts the room into the range where
  /// the VAD starts scoring it as speech — which trades missed speech for
  /// hallucinated speech, a worse failure. Capping the amplified noise floor
  /// means the boost is large in a quiet room, where it is safe and where quiet
  /// speech actually needs it, and near unity in a loud one, where it would not
  /// have helped anyway.
  final double noiseCeiling;

  /// How far back the noise floor estimate looks.
  ///
  /// Long enough to span a sentence, because the estimate is a running minimum
  /// and anything shorter starts mistaking the gaps between words for the room.
  /// Speech with no pause at all for longer than this does pull the estimate up
  /// and the gain down; that is the known cost of minimum statistics, and it
  /// self-corrects at the next breath. Somebody who never pauses is also
  /// somebody whose speech is already being detected.
  final Duration noiseWindow;

  /// Envelope rise time. Short, so a syllable's onset is not swallowed.
  final Duration attack;

  /// Envelope fall time. Long relative to [attack] so the follower rides over
  /// the gaps inside a word instead of pumping through them.
  final Duration release;

  /// Time constant for gain going **up**.
  ///
  /// Separate from the envelope on purpose: the envelope must be quick to
  /// respond, but the *gain* moving quickly is audible as pumping and, worse,
  /// alters the amplitude contour the VAD reads. Gliding it slowly keeps the
  /// applied gain effectively constant within any one utterance.
  final Duration gainRise;

  /// Time constant for gain coming **down**, deliberately much shorter.
  ///
  /// Asymmetric because the two directions have different consequences. Coming
  /// up late costs a slightly quiet first syllable; coming down late costs a
  /// clipped one, and the limiter that catches it distorts exactly the loud
  /// onset the model most needs to hear.
  final Duration gainFall;

  /// How far above the noise floor the current block must sit before the gain
  /// is allowed to move, as a multiple of the noise RMS.
  ///
  /// This is the AGC "hold". Without it the gain winds all the way up during
  /// every pause — there is no signal, so the target says amplify — and then
  /// the next sentence opens at full boost and is ducked over the following
  /// syllable. The result is an overshoot on the first word of every utterance,
  /// which is the word the pre-roll exists to protect. Holding the gain where
  /// speech last set it means each utterance opens at the gain that suited the
  /// last one, which is very nearly always the right guess.
  final double signalMargin;

  /// Peak the gain is not allowed to push the signal past.
  ///
  /// The crest-factor problem, solved by measuring instead of guessing. A level
  /// target alone cannot bound the peak, because how far a peak sits above the
  /// average is a property of the speaker and the room, not of the
  /// configuration — so a target chosen for one voice clips another. Capping
  /// gain at `peakCeiling / peak` bounds it directly, whatever the crest factor
  /// turns out to be.
  ///
  /// Held below [limit] on purpose: the peak follower is fast but not
  /// instantaneous, and the gap is the headroom it needs to be late in.
  final double peakCeiling;

  /// Hard backstop. Reaching this means [peakCeiling] was already exceeded, so
  /// it should be rare — and unlike a gain cap, clamping distorts. That is the
  /// whole reason the gain cap exists.
  final double limit;

  NormalizerConfig copyWith({
    double? targetLevel,
    double? maxGain,
    double? noiseCeiling,
    double? minGain,
    Duration? noiseWindow,
    Duration? attack,
    Duration? release,
    Duration? gainRise,
    Duration? gainFall,
    double? signalMargin,
    double? peakCeiling,
    double? limit,
  }) {
    return NormalizerConfig(
      targetLevel: targetLevel ?? this.targetLevel,
      maxGain: maxGain ?? this.maxGain,
      minGain: minGain ?? this.minGain,
      noiseCeiling: noiseCeiling ?? this.noiseCeiling,
      noiseWindow: noiseWindow ?? this.noiseWindow,
      attack: attack ?? this.attack,
      release: release ?? this.release,
      gainRise: gainRise ?? this.gainRise,
      gainFall: gainFall ?? this.gainFall,
      signalMargin: signalMargin ?? this.signalMargin,
      peakCeiling: peakCeiling ?? this.peakCeiling,
      limit: limit ?? this.limit,
    );
  }
}

/// Automatic gain control for the head of the pipeline.
///
/// Sits between the microphone ring and the VAD, so the endpointer, and
/// therefore the decoder, both see the normalized audio. One stage, both
/// benefits: the VAD stops missing quiet speech, and the model stops being
/// handed clips ten times quieter than anything in its training set.
///
/// The interesting part is the cap. A plain AGC amplifies whatever it is given,
/// which in a noisy room means amplifying noise into the VAD's speech range.
/// This one estimates the noise floor by running minimum statistics over
/// [NormalizerConfig.noiseWindow] and refuses to raise it past
/// [NormalizerConfig.noiseCeiling]. So the boost is large exactly where it is
/// useful and safe — a quiet voice in a quiet room — and folds back to unity in
/// conditions where gain could not have helped.
///
/// Not thread-safe, and stateful across calls: one instance per audio stream.
/// [reset] it wherever the stream is not contiguous, alongside the VAD's own
/// reset, or the envelope carries a level from before the gap.
class AudioNormalizer {
  AudioNormalizer({
    this.config = const NormalizerConfig(),
    this.sampleRate = vadSampleRate,
  });

  final NormalizerConfig config;
  final int sampleRate;

  /// Samples between noise-floor updates. 512 at 16 kHz is 32 ms, the same
  /// granularity the VAD works at; nothing depends on them matching.
  static const _blockSamples = 512;

  late final double _attackCoef = _coefficient(config.attack, sampleRate);
  late final double _releaseCoef = _coefficient(config.release, sampleRate);
  late final double _peakCoef = _coefficient(
    const Duration(milliseconds: 250),
    sampleRate,
  );
  late final double _riseCoef = _coefficient(config.gainRise, sampleRate);
  late final double _fallCoef = _coefficient(config.gainFall, sampleRate);
  late final int _windowBlockCount = math.max(
    1,
    (config.noiseWindow.inMicroseconds * sampleRate / 1000000 / _blockSamples)
        .round(),
  );

  double _envelope = 0;
  double _gain = 1;

  /// True peak: instant attack, short decay.
  ///
  /// Separate from [_envelope], which is deliberately slow to fall and
  /// therefore blind to exactly the transients that clip. This one rises the
  /// instant a sample does, so the gain cap it feeds is in place *before* the
  /// peak is amplified rather than after.
  double _peak = 0;

  /// Running minima of block RMS, oldest first. The noise floor is the smaller
  /// of the two, which makes it a minimum over between one and two
  /// [NormalizerConfig.noiseWindow]s — the cheap standard trick for a sliding
  /// minimum without a deque.
  ///
  /// Measured as plain RMS over each 32 ms block rather than from [_envelope].
  /// The envelope is deliberately slow to fall, so between two utterances it is
  /// still decaying from the last one and reads the room as far louder than it
  /// is — which caps the gain exactly when a quiet speaker needs it. An
  /// unsmoothed block RMS sees the true floor in the first quiet block.
  double _previousWindowMin = double.infinity;
  double _windowMin = double.infinity;
  double _blockSum = 0;
  double _noise = 0;

  /// RMS of the most recently completed block.
  ///
  /// The "is anyone talking" test, kept separate from [_envelope] because the
  /// two need opposite dynamics. The envelope must fall slowly, so it rides
  /// over the gaps inside a word — which also means that half a second after a
  /// sentence ends it still reads loud, and a hold gated on it would never
  /// engage. An unsmoothed block RMS reports the pause within 32 ms.
  double _blockRms = 0;
  int _blockFill = 0;
  int _windowFill = 0;

  /// Gain currently being applied, for a diagnostic readout.
  double get gain => _gain;

  /// Current estimate of the room's noise floor, as RMS. Zero until the first
  /// block has been measured.
  double get noiseFloor => _noise;

  /// RMS of the most recent 32 ms of **input**, before gain.
  ///
  /// The level the microphone actually delivered. Worth reporting: it is the
  /// quantity that decides whether the VAD and the model can work at all, and
  /// unlike room loudness in dB SPL it needs no instrument and carries no
  /// assumption about how far from the phone the speaker was sitting.
  double get inputRms => _blockRms;

  /// Peak of the recent input, before gain.
  double get inputPeak => _peak;

  /// Applies gain to [samples] **in place** and returns the same list.
  ///
  /// In place because the caller owns a fresh copy out of the ring and the next
  /// stage copies again; adding a third buffer to the hot path would be pure
  /// allocation. Callers who need the original audio must copy it first.
  Float32List process(Float32List samples) {
    final limit = config.limit;
    for (var i = 0; i < samples.length; i++) {
      final x = samples[i];
      final level = x < 0 ? -x : x;

      _envelope = level > _envelope
          ? _attackCoef * _envelope + (1 - _attackCoef) * level
          : _releaseCoef * _envelope + (1 - _releaseCoef) * level;

      _peak = level > _peak ? level : _peakCoef * _peak;
      _blockSum += x * x;
      if (++_blockFill >= _blockSamples) _rollBlock();

      final target = _targetGain();
      final coef = target > _gain ? _riseCoef : _fallCoef;
      _gain = coef * _gain + (1 - coef) * target;

      final y = x * _gain;
      samples[i] = y > limit
          ? limit
          : y < -limit
          ? -limit
          : y;
    }
    return samples;
  }

  /// Clears the envelope, the gain, and the noise estimate.
  ///
  /// Call this wherever the audio stream is not contiguous — a dropout, an
  /// interruption, a route change. Carrying an envelope across a gap means
  /// applying the gain for the old room, and carrying it across a device change
  /// means applying the gain for the old microphone's sensitivity.
  void reset() {
    _envelope = 0;
    _gain = 1;
    _peak = 0;
    _previousWindowMin = double.infinity;
    _windowMin = double.infinity;
    _blockSum = 0;
    _blockRms = 0;
    _noise = 0;
    _blockFill = 0;
    _windowFill = 0;
  }

  double _targetGain() {
    // Nothing but room tone right now. Silence carries no information about the
    // right gain for the speech that follows it, so hold what speech last set.
    if (_blockRms < math.max(config.signalMargin * _noise, 1e-6)) return _gain;

    // No noise estimate yet: the first block is still filling, so decline to
    // boost rather than boost blind.
    // The noise cap only ever limits boost: attenuating cannot lift a room's
    // floor, so it has no business forcing gain down.
    final noiseCap = _noise > 1e-7
        ? math.max(1.0, config.noiseCeiling / _noise)
        : 1.0;
    // The peak cap is the one that may push below unity, and must — that is
    // how loud input gets brought down instead of clipped.
    final peakCap = _peak > 1e-7 ? config.peakCeiling / _peak : config.maxGain;

    final upper = math.max(
      config.minGain,
      math.min(config.maxGain, math.min(noiseCap, peakCap)),
    );
    final desired = config.targetLevel / _envelope;
    return math.min(math.max(desired, config.minGain), upper);
  }

  void _rollBlock() {
    final rms = math.sqrt(_blockSum / _blockSamples);
    _blockRms = rms;
    _blockFill = 0;
    _blockSum = 0;
    if (rms < _windowMin) _windowMin = rms;

    if (++_windowFill >= _windowBlockCount) {
      _windowFill = 0;
      _previousWindowMin = _windowMin;
      _windowMin = double.infinity;
    }

    final low = math.min(_previousWindowMin, _windowMin);
    _noise = low.isFinite ? low : 0;
  }

  static double _coefficient(Duration tau, int sampleRate) {
    final samples = tau.inMicroseconds * sampleRate / 1000000;
    if (samples <= 0) return 0;
    return math.exp(-1 / samples);
  }
}
