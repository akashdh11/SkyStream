/// Registering a stream's side-car subtitles with the engine without letting
/// arrival order decide which language the viewer gets.
///
/// [VlcPlayerController.addSubtitle] maps onto libVLC's *add slave* with the
/// select flag hardcoded `true` in all five native backends (Kotlin's
/// `addSlave(..., true)`, `enforce: true` on both Swift plugins, and the same
/// in the two C++ ones). Every call therefore enables what it just added, so a
/// source shipping English, Spanish and Portuguese side-cars plays Portuguese
/// — and because the adds are fired off unawaited, "last" really means
/// "whichever platform round-trip finished last", which is not even stable
/// between runs.
///
/// Turning that flag into a parameter is a five-backend change. The engine
/// does now report which SPU track is on
/// (`VlcPlayerValue.activeSubtitleTrackId`, re-sent after every add), so the
/// previous selection *could* be read back and restored afterwards - but that
/// is a select-then-unselect on every side-car, each one a flash of the wrong
/// language on screen. Better to stop leaving the choice to chance in the first
/// place: add them in a known order, then state once, explicitly, which one
/// should be on. The panel's tick then follows that final `setSubtitleTrack`
/// through the engine's own snapshot.
library;

import 'package:vlc_player/vlc_player.dart';

/// Adds [uris] to [controller] in order and leaves the [enable]-th of them
/// selected.
///
/// The adds are sequential on purpose — that is what makes "which subtitle is
/// on when this returns" answerable at all.
///
/// [enable] indexes into [uris], not into the engine's track list. `null` means
/// the caller has no preference, and the last side-car stays on because the
/// select flag gives us no way to ask for otherwise.
///
/// New side-car tracks are identified by diffing the engine's subtitle list
/// around the batch: libVLC hands each slave a fresh id, so the ids that were
/// not there before are exactly these files, in the order they were added.
Future<void> addSideCarSubtitles(
  VlcPlayerController controller,
  List<Uri> uris, {
  int? enable,
}) async {
  if (uris.isEmpty) return;

  // Only worth a round-trip when the answer can change what we do next: if the
  // last one is wanted, VLC's select flag has already delivered it.
  final wantsEarlier =
      enable != null && enable >= 0 && enable < uris.length - 1;
  final before = wantsEarlier
      ? (await controller.getSubtitleTracks()).map((t) => t.id).toSet()
      : const <int>{};

  for (final uri in uris) {
    await controller.addSubtitle(uri);
  }
  if (!wantsEarlier) return;

  final added = (await controller.getSubtitleTracks())
      .where((t) => !before.contains(t.id))
      .toList();
  if (enable < added.length) {
    await controller.setSubtitleTrack(added[enable].id);
  }
}

/// Index of the first entry in [languages] written in [preferred], or `null`
/// when nothing matches.
///
/// Tags are compared on their primary subtag only, so a `pt-BR` side-car
/// satisfies a `pt` preference. Three-letter ISO 639-2 tags are deliberately
/// *not* folded into their two-letter forms: the mapping is not derivable and a
/// hand-written table here would quietly rot. Source metadata should be
/// normalised where it is parsed, not guessed at here.
int? preferredSubtitleIndex(List<String?> languages, String? preferred) {
  final want = _primarySubtag(preferred);
  if (want == null) return null;
  for (var i = 0; i < languages.length; i++) {
    if (_primarySubtag(languages[i]) == want) return i;
  }
  return null;
}

/// Lowercased language part of a BCP 47-ish tag, or `null` when the tag says
/// nothing — `und` is what sources emit when they mean "no idea".
String? _primarySubtag(String? tag) {
  if (tag == null) return null;
  final primary = tag.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'und') return null;
  return primary;
}
