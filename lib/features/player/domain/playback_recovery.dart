/// The two decisions the player makes when the network stops cooperating.
///
/// Both are pure, and both live here rather than in the screen, because the
/// screen owns a native surface that no test can drive — the logic that
/// decides *when* to give up on a source and *which* source to try next is the
/// part worth proving, and it does not need an engine to be proved.
library;

/// What to do about a picture that has stopped moving.
enum StallAction {
  /// Nothing yet. Either playback is fine or the stall is too young to act on.
  none,

  /// Re-issue the current position and resume.
  ///
  /// Cheap, and often enough on its own: a demuxer that dropped its request
  /// after a Range response it disliked starts a new one, and a stream the
  /// engine quietly parked simply resumes.
  nudge,

  /// This source has had its chance — hand it to the failover ladder, which
  /// decides between reopening it and moving on.
  recover,
}

/// How long a source that has produced frames may sit at one position before
/// the engine gets a kick.
///
/// Long enough that an ordinary rebuffer on a slow connection rides it out —
/// a nudge forces a fresh request, which on a stream that is merely refilling
/// its buffer costs more than it saves.
const Duration kStallNudgeAfter = Duration(seconds: 10);

/// How long any source may make no progress at all before it is abandoned.
const Duration kStallRecoverAfter = Duration(seconds: 25);

/// A torrent's first frame waits on pieces arriving, not on a socket, and on a
/// cold magnet that is measured in minutes. Applying the ordinary deadline to
/// one would abandon every torrent before it ever had a chance to seed.
const Duration kTorrentStallRecoverAfter = Duration(minutes: 3);

/// Whether a stall of [stalledFor] warrants doing something about it yet.
///
/// The input is deliberately elapsed-time-since-progress rather than the
/// engine's state enum: libVLC reports `buffering` throughout healthy playback
/// on some builds, so a watchdog driven by the enum fires constantly. An
/// advancing position is the only trustworthy sign of playback, which is the
/// same signal the progress recorder already gates on.
///
/// [lastAction] is the highest rung already fired for this stall window, so
/// each rung fires once; the caller clears it the moment the position moves.
/// The rungs are tested in descending severity rather than in order, so a
/// freeze that is only noticed late — a suspended laptop, a device that missed
/// a minute of ticks — escalates straight to recovery instead of walking the
/// ladder a second at a time.
StallAction stallActionFor({
  required Duration stalledFor,
  required bool hadFrames,
  required StallAction lastAction,
  Duration recoverAfter = kStallRecoverAfter,
}) {
  if (stalledFor >= recoverAfter && lastAction != StallAction.recover) {
    return StallAction.recover;
  }
  // Nothing has been decoded yet, so there is no position to seek back to and
  // no demuxer to unstick. Waiting out the deadline is the only move.
  if (!hadFrames) return StallAction.none;
  if (stalledFor >= kStallNudgeAfter && lastAction == StallAction.none) {
    return StallAction.nudge;
  }
  return StallAction.none;
}

/// The next candidate to open after [from], or null once every one has had a
/// turn.
///
/// Walks the ring rather than counting upwards. The first source opened is
/// whichever the resolver picked — the saved-source index, or the health
/// probe's choice — and that is routinely not zero, so counting upwards leaves
/// every candidate before it permanently unreachable by failover.
///
/// [tried] is what stops the ring becoming a loop: the caller records every
/// index it opens, so the walk visits each candidate exactly once and then
/// gives up. It is a *walk's* memory, not the session's — a source that plays
/// for an hour before the network drops has earned a fresh walk.
int? nextFailoverIndex({
  required int from,
  required int total,
  required Set<int> tried,
}) {
  if (total <= 0) return null;
  for (var step = 1; step <= total; step++) {
    final candidate = (from + step) % total;
    if (!tried.contains(candidate)) return candidate;
  }
  return null;
}
