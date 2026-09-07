import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'vlc_player_error.dart';

/// Playback lifecycle states reported by the native VLC player.
enum VlcPlaybackState {
  /// No media is loaded.
  idle,

  /// VLC is opening the current media.
  opening,

  /// VLC is buffering enough data to continue playback.
  buffering,

  /// Media is currently playing.
  playing,

  /// Media playback is paused.
  paused,

  /// Playback has been stopped.
  stopped,

  /// The current media reached the end.
  ended,

  /// The player is in an error state.
  error,
}

/// Why the system, rather than the viewer, changed playback.
///
/// Audio is an exclusive resource on a phone: a call, a navigation prompt or
/// another media app all expect whatever is playing to get out of the way, and
/// nothing in libVLC knows that. The native side does, and it acts in the same
/// instant — a round trip to Dart would leave a film talking over the first
/// ring — so this is a report of what already happened, not a request.
///
/// A host that shows nothing for these is still correct: [VlcPlayerValue.state]
/// already says `paused`. This says *why*, which is the difference between a
/// player that looks broken and one that explains itself.
enum VlcAudioInterruption {
  /// Nothing is interrupting playback.
  none,

  /// Audio went to another app for good, and playback is paused.
  ///
  /// Only the viewer restarts this one. Android reports it as
  /// `AUDIOFOCUS_LOSS`; iOS as an interruption that ended without advising a
  /// resume.
  focusLost,

  /// Audio went to something short-lived — typically a phone call — and
  /// playback is paused until it comes back.
  ///
  /// This is the only interruption the controller resumes from by itself.
  focusLostTransient,

  /// Something is talking over the top and playback continues, attenuated.
  ///
  /// Android only (`AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`). Ducking beats
  /// pausing for a navigation prompt, and the viewer's chosen
  /// [VlcPlayerValue.volume] is untouched — the attenuation is applied under
  /// it and lifted when the prompt finishes.
  ducked,

  /// The output device went away and playback is paused.
  ///
  /// Headphones pulled out, or Bluetooth dropped. Resuming would blare the
  /// film out of the phone speaker, so this never resumes on its own.
  becameNoisy,
}

/// Immutable snapshot of the native player state.
///
/// Listen to `VlcPlayerController` to receive updated values as VLC emits
/// playback events.
@immutable
class VlcPlayerValue {
  /// Creates a player value snapshot.
  const VlcPlayerValue({
    this.state = VlcPlaybackState.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.playbackSpeed = 1,
    this.audioDelay = Duration.zero,
    this.subtitleDelay = Duration.zero,
    this.activeAudioTrackId,
    this.activeSubtitleTrackId,
    this.trackRevision = 0,
    this.isReady = false,
    this.isSeekable = false,
    this.isLive = false,
    this.isStalled = false,
    this.interruption = VlcAudioInterruption.none,
    this.videoSize,
    this.codedVideoSize,
    this.bufferingProgress,
    this.error,
    this.errorDescription,
  });

  /// Current playback lifecycle state.
  final VlcPlaybackState state;

  /// Current playback position.
  final Duration position;

  /// Current media duration, or [Duration.zero] when unknown.
  final Duration duration;

  /// Current VLC volume.
  ///
  /// VLC volume is generally represented as `0..200`, where `100` is normal
  /// volume.
  final int volume;

  /// Current playback speed multiplier.
  final double playbackSpeed;

  /// Current audio playback delay.
  ///
  /// Positive values delay audio; negative values play audio earlier.
  final Duration audioDelay;

  /// Current subtitle display delay.
  ///
  /// Positive values delay subtitles; negative values show subtitles earlier.
  final Duration subtitleDelay;

  /// The id of the audio track the engine is currently playing, or null when
  /// there is none.
  ///
  /// Null covers every "nothing" the engine can mean: no media loaded, media
  /// with no audio elementary stream, or a track list not yet parsed. libVLC
  /// itself reports these as `-1`, and that pseudo-id is normalised to null
  /// here, once, so no consumer has to compare against it. `0` is a legal
  /// track id and is passed through untouched.
  ///
  /// Ids are the same native ids [VlcTrackDescription.id] carries, so a
  /// selected-row check is `track.id == value.activeAudioTrackId`. Every
  /// backend re-sends its snapshot after `setAudioTrack` and after each seek,
  /// so a selection made through the controller shows up here without a
  /// pull; an engine-initiated switch is reported on the next tick.
  final int? activeAudioTrackId;

  /// The id of the subtitle track the engine is currently rendering, or null
  /// when subtitles are off.
  ///
  /// Null means the same as for [activeAudioTrackId] - no media, no text
  /// stream, or an explicit `disableSubtitle()` - and is likewise the
  /// normalised form of libVLC's `-1`, so "subtitles off" is a null check and
  /// never a magic-number compare. `0` is a legal id. Re-sent by every
  /// backend after `setSubtitleTrack`, `disableSubtitle` and each seek: each
  /// of those is a synchronous write on the player that reads straight back,
  /// so the snapshot forced after the call already carries the new id.
  ///
  /// `addSubtitle` is deliberately not in that list. libVLC 3 hands an added
  /// slave to the input thread rather than applying it inline, so on all five
  /// backends the snapshot forced immediately after the call still describes
  /// the pre-add state — the future completing means "the engine accepted the
  /// slave", not "the track is in the list now". The side-car surfaces when
  /// the engine announces the new elementary stream (`.esAdded` on macOS and
  /// iOS, `MediaPlayer.Event.ESAdded` on Android, the next 500 ms poll on
  /// Windows and Linux), and that is what moves [trackRevision]. Key off
  /// [trackRevision], never off the `addSubtitle` future.
  final int? activeSubtitleTrackId;

  /// A counter that moves whenever the engine's track list changes shape.
  ///
  /// Monotonic per player, starting at `0`, and bumped when the audio +
  /// subtitle track *set* changes — not merely when its size changes. macOS,
  /// iOS, Windows and Linux hash the ids and names of both lists into every
  /// snapshot and bump when that hash moves, so a same-size swap (an adaptive
  /// rendition change, an MPEG-TS PMT update) is caught too; Android bumps on
  /// an audio or subtitle `ESAdded` / `ESDeleted`, and deliberately not on a
  /// video-only one. A demuxer finishing its parse, a side-car file landing
  /// through `addSubtitle`, a stream dropping a language all move it.
  ///
  /// Because `addSubtitle` converges asynchronously, this — not the
  /// completion of the call — is the signal that an added side-car exists.
  /// Consumers that cache `getAudioTracks()` / `getSubtitleTracks()` results
  /// should refetch when this differs from the revision they fetched under,
  /// rather than polling. The number itself carries no meaning beyond
  /// "changed since".
  final int trackRevision;

  /// Whether the native player has reached a playable active or terminal state.
  final bool isReady;

  /// Whether VLC reports that the current media can seek.
  final bool isSeekable;

  /// Whether the current media looks like a live stream.
  final bool isLive;

  /// Whether playback has visibly stopped making progress while [state] still
  /// says it is running.
  ///
  /// This is the mid-play spinner signal, and it deliberately does not come
  /// from libVLC's state machine. libVLC 3 keeps reporting `playing` through a
  /// rebuffer on every platform but Android, so [isBuffering] can only ever
  /// describe the startup buffer. What does betray a stall is the position
  /// clock standing still, and the controller - not the natives - watches that
  /// clock and raises this once it has stood still for
  /// `VlcPlayerController.stallIndicatorDelay`. It is only ever true while
  /// [state] is [VlcPlaybackState.playing] or [VlcPlaybackState.buffering]: a
  /// paused, stopped, ended or errored player is not stalled, it is what it
  /// says it is.
  final bool isStalled;

  /// Why the system last interrupted playback, if it has.
  final VlcAudioInterruption interruption;

  /// Decoded video size when VLC exposes it.
  final Size? videoSize;

  /// The decoder's buffer size on a texture-backed player, when it differs
  /// from [videoSize].
  ///
  /// Decoders pad height to a multiple of 16, so a 1080p stream decodes into
  /// 1920x1088 with eight rows nobody writes - and unwritten NV12 is green.
  /// The texture is that whole buffer; the widget uses this to clip it back
  /// to the visible picture. Null for view-backed players, whose drawable
  /// already crops.
  final Size? codedVideoSize;

  /// Normalized buffering progress from `0.0` to `1.0`, when available.
  final double? bufferingProgress;

  /// Structured playback error when [state] is [VlcPlaybackState.error].
  final VlcPlayerError? error;

  /// Human-readable playback error text when available.
  final String? errorDescription;

  /// Whether [state] is [VlcPlaybackState.playing].
  bool get isPlaying => state == VlcPlaybackState.playing;

  /// Whether [state] is [VlcPlaybackState.buffering].
  bool get isBuffering => state == VlcPlaybackState.buffering;

  /// Whether [state] is [VlcPlaybackState.error].
  bool get hasError => state == VlcPlaybackState.error;

  /// Whether the system is currently interrupting playback.
  bool get isInterrupted => interruption != VlcAudioInterruption.none;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is VlcPlayerValue &&
        other.state == state &&
        other.position == position &&
        other.duration == duration &&
        other.volume == volume &&
        other.playbackSpeed == playbackSpeed &&
        other.audioDelay == audioDelay &&
        other.subtitleDelay == subtitleDelay &&
        other.activeAudioTrackId == activeAudioTrackId &&
        other.activeSubtitleTrackId == activeSubtitleTrackId &&
        other.trackRevision == trackRevision &&
        other.isReady == isReady &&
        other.isSeekable == isSeekable &&
        other.isLive == isLive &&
        other.isStalled == isStalled &&
        other.interruption == interruption &&
        other.videoSize == videoSize &&
        other.codedVideoSize == codedVideoSize &&
        other.bufferingProgress == bufferingProgress &&
        other.error == error &&
        other.errorDescription == errorDescription;
  }

  @override
  int get hashCode => Object.hash(
    state,
    position,
    duration,
    volume,
    playbackSpeed,
    audioDelay,
    subtitleDelay,
    activeAudioTrackId,
    activeSubtitleTrackId,
    trackRevision,
    isReady,
    isSeekable,
    isLive,
    isStalled,
    interruption,
    videoSize,
    codedVideoSize,
    bufferingProgress,
    error,
    errorDescription,
  );

  /// Returns a copy with selected fields replaced.
  ///
  /// Set [clearVideoSize], [clearBufferingProgress], [clearError],
  /// [clearActiveAudioTrack], or [clearActiveSubtitleTrack] to remove
  /// nullable values that would otherwise be preserved from the current value.
  VlcPlayerValue copyWith({
    VlcPlaybackState? state,
    Duration? position,
    Duration? duration,
    int? volume,
    double? playbackSpeed,
    Duration? audioDelay,
    Duration? subtitleDelay,
    int? activeAudioTrackId,
    bool clearActiveAudioTrack = false,
    int? activeSubtitleTrackId,
    bool clearActiveSubtitleTrack = false,
    int? trackRevision,
    bool? isReady,
    bool? isSeekable,
    bool? isLive,
    bool? isStalled,
    VlcAudioInterruption? interruption,
    Size? videoSize,
    bool clearVideoSize = false,
    Size? codedVideoSize,
    double? bufferingProgress,
    bool clearBufferingProgress = false,
    VlcPlayerError? error,
    String? errorDescription,
    bool clearError = false,
  }) {
    final nextError = clearError
        ? null
        : error ??
              (errorDescription == null
                  ? this.error
                  : VlcPlayerError(
                      code: VlcPlayerErrorCode.playbackError,
                      message: errorDescription,
                    ));
    final nextErrorDescription = clearError
        ? null
        : error != null
        ? error.message
        : errorDescription ?? this.errorDescription;
    return VlcPlayerValue(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      audioDelay: audioDelay ?? this.audioDelay,
      subtitleDelay: subtitleDelay ?? this.subtitleDelay,
      activeAudioTrackId: clearActiveAudioTrack
          ? null
          : activeAudioTrackId ?? this.activeAudioTrackId,
      activeSubtitleTrackId: clearActiveSubtitleTrack
          ? null
          : activeSubtitleTrackId ?? this.activeSubtitleTrackId,
      trackRevision: trackRevision ?? this.trackRevision,
      isReady: isReady ?? this.isReady,
      isSeekable: isSeekable ?? this.isSeekable,
      isLive: isLive ?? this.isLive,
      isStalled: isStalled ?? this.isStalled,
      interruption: interruption ?? this.interruption,
      videoSize: clearVideoSize ? null : videoSize ?? this.videoSize,
      // Cleared together with videoSize: both describe the same picture, and
      // a stale coded size against a fresh visible one would clip wrongly.
      codedVideoSize: clearVideoSize
          ? null
          : codedVideoSize ?? this.codedVideoSize,
      bufferingProgress: clearBufferingProgress
          ? null
          : bufferingProgress ?? this.bufferingProgress,
      error: nextError,
      errorDescription: nextErrorDescription,
    );
  }

  /// Converts a native event-channel payload into a player value.
  ///
  /// Unknown or malformed events leave [previous] unchanged.
  static VlcPlayerValue fromEvent(Object? event, VlcPlayerValue previous) {
    if (event is! Map) {
      return previous;
    }

    var state =
        _stateFromString(_stringValue(event['state'])) ?? previous.state;

    // libVLC's state machine cannot be taken at face value. VLCKit reports
    // `buffering` for the whole of healthy playback with `isPlaying` false, and
    // libVLC on Android emits a Buffering event on nearly every tick. A
    // consumer that trusts the enum shows a spinner over a playing video and,
    // worse, never learns that playback started at all.
    //
    // An advancing position cannot lie, so it corrects the enum here - once,
    // for every platform and every consumer - rather than in each UI that hits
    // the problem.
    //
    // Deliberately narrow. The correction applies only when playback was
    // ALREADY running and the position moved forward, which is exactly the
    // spurious case. A genuine buffer at startup arrives from `opening`, and a
    // genuine rebuffer mid-playback does not advance the position - both are
    // left alone, as are paused, stopped, ended and error.
    if (state == VlcPlaybackState.buffering &&
        previous.state == VlcPlaybackState.playing) {
      final position = _durationFromMilliseconds(event['position']);
      if (position != null && position > previous.position) {
        state = VlcPlaybackState.playing;
      }
    }
    final hasVideoSize = event.containsKey('videoSize');
    final videoSize = hasVideoSize ? _sizeFromMap(event['videoSize']) : null;
    final codedVideoSize = event.containsKey('codedSize')
        ? _sizeFromMap(event['codedSize'])
        : null;
    final hasBufferingProgress = event.containsKey('bufferingProgress');
    final bufferingProgress = hasBufferingProgress
        ? _normalizedProgress(event['bufferingProgress'])
        : null;
    final error = _errorFromEvent(event);
    // Track ids: an absent key keeps the previous value (older natives and
    // test fixtures send none), while a present key that is not a usable id -
    // libVLC's -1 for "none/off" - clears it to null.
    final hasAudioTrack = event.containsKey('audioTrack');
    final audioTrack = _trackIdValue(event['audioTrack']);
    final hasSubtitleTrack = event.containsKey('subtitleTrack');
    final subtitleTrack = _trackIdValue(event['subtitleTrack']);

    // isStalled is deliberately not read from the event. No native backend can
    // report it - see the field - so it is carried over from [previous] and
    // owned entirely by the controller's position clock.
    return previous.copyWith(
      state: state,
      position: _durationFromMilliseconds(event['position']),
      duration: _durationFromMilliseconds(event['duration']),
      volume: _intValue(event['volume']),
      playbackSpeed: _doubleValue(event['playbackSpeed']),
      audioDelay: _durationFromMicroseconds(event['audioDelay']),
      subtitleDelay: _durationFromMicroseconds(event['subtitleDelay']),
      activeAudioTrackId: audioTrack,
      clearActiveAudioTrack: hasAudioTrack && audioTrack == null,
      activeSubtitleTrackId: subtitleTrack,
      clearActiveSubtitleTrack: hasSubtitleTrack && subtitleTrack == null,
      trackRevision: _intValue(event['trackRevision']),
      isReady: _boolValue(event['isReady']) ?? _isReadyState(state),
      isSeekable: _boolValue(event['isSeekable']),
      isLive: _boolValue(event['isLive']),
      interruption: _interruptionFromString(
        _stringValue(event['interruption']),
      ),
      videoSize: videoSize,
      codedVideoSize: codedVideoSize,
      clearVideoSize:
          (hasVideoSize && videoSize == null) || _clearsVideoSize(state),
      bufferingProgress: bufferingProgress,
      clearBufferingProgress:
          (hasBufferingProgress && bufferingProgress == null) ||
          state != VlcPlaybackState.buffering,
      error: error,
      errorDescription: error?.message,
      clearError: error == null,
    );
  }

  static Duration? _durationFromMilliseconds(Object? value) {
    if (value is! num || value < 0 || !value.isFinite) {
      return null;
    }
    return Duration(milliseconds: value.round());
  }

  static Duration? _durationFromMicroseconds(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return Duration(microseconds: value.round());
  }

  static Size? _sizeFromMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final width = _doubleValue(value['width']);
    final height = _doubleValue(value['height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  static double? _normalizedProgress(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return value.toDouble().clamp(0.0, 1.0).toDouble();
  }

  static VlcPlayerError? _errorFromEvent(Map<Object?, Object?> event) {
    final rawError = event['error'];
    if (rawError is Map) {
      return VlcPlayerError.fromMap(rawError.cast<Object?, Object?>());
    }

    final code = _stringValue(event['errorCode']);
    final description = _stringValue(event['errorDescription']);
    if (code == null && description == null) {
      return null;
    }
    return VlcPlayerError(
      code: code ?? VlcPlayerErrorCode.playbackError,
      message: description,
      details: event['errorDetails'],
    );
  }

  static bool _isReadyState(VlcPlaybackState state) {
    return switch (state) {
      VlcPlaybackState.playing ||
      VlcPlaybackState.paused ||
      VlcPlaybackState.stopped ||
      VlcPlaybackState.ended => true,
      _ => false,
    };
  }

  static bool _clearsVideoSize(VlcPlaybackState state) {
    return switch (state) {
      VlcPlaybackState.idle ||
      VlcPlaybackState.opening ||
      VlcPlaybackState.error => true,
      _ => false,
    };
  }

  static String? _stringValue(Object? value) => value is String ? value : null;

  /// A native track id, or null for anything that is not one: libVLC's `-1`
  /// "none" pseudo-id, non-numeric junk, NaN. `0` is a valid id.
  static int? _trackIdValue(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.round() : null;

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num && value.isFinite) {
      return value.round();
    }
    return null;
  }

  static double? _doubleValue(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return value.toDouble();
  }

  static bool? _boolValue(Object? value) => value is bool ? value : null;

  /// An absent or unrecognised name leaves the current interruption alone.
  ///
  /// Only Android and iOS have an audio session to report on, so most events
  /// carry no interruption at all; reading that as "the interruption ended"
  /// would resume a film in the middle of a phone call.
  static VlcAudioInterruption? _interruptionFromString(String? value) {
    return switch (value) {
      'none' => VlcAudioInterruption.none,
      'focusLost' => VlcAudioInterruption.focusLost,
      'focusLostTransient' => VlcAudioInterruption.focusLostTransient,
      'ducked' => VlcAudioInterruption.ducked,
      'becameNoisy' => VlcAudioInterruption.becameNoisy,
      _ => null,
    };
  }

  static VlcPlaybackState? _stateFromString(String? value) {
    return switch (value) {
      'idle' => VlcPlaybackState.idle,
      'opening' => VlcPlaybackState.opening,
      'buffering' => VlcPlaybackState.buffering,
      'playing' => VlcPlaybackState.playing,
      'paused' => VlcPlaybackState.paused,
      'stopped' => VlcPlaybackState.stopped,
      'ended' => VlcPlaybackState.ended,
      'error' => VlcPlaybackState.error,
      _ => null,
    };
  }
}
