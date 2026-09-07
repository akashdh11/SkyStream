/// The Audio and Subtitles tabs.
///
/// The engine owns the track list — nothing here caches, mirrors or merges it,
/// which is the decision that let the old controller's reload-reconciliation
/// machinery be deleted rather than ported when the bottom sheets became this
/// panel (see player_panel.dart).
///
/// The engine owns the *selection* too. `VlcPlayerValue.activeAudioTrackId`
/// and `activeSubtitleTrackId` say which track is rendering right now, every
/// native re-sends its snapshot after a set/disable/add, and so the tick is
/// read straight off the controller: nothing is remembered optimistically, a
/// tap is the bare engine call, and a set the engine refuses never moves the
/// tick because the engine never said it did. `null` is "none" - libVLC's `-1`
/// is normalised in the package, so it is never compared against here.
///
/// "Bare" stops at the error: a row's `onTap` is unawaited, so every engine
/// call here goes through `_setTrack` or `_step`, which absorb the refusal
/// rather than throw it into the zone. A refused *set* also re-reads the list,
/// because a refusal is the engine saying the row should not have been there.
///
/// Adding a track is the one call whose result the engine cannot report in
/// time, and the tab does not pretend otherwise: nothing re-reads the list
/// after `addSubtitle`. See [PlayerTracksTab.onTracksChanged].
///
/// What this adds over the engine is naming. libVLC hands back `Track 3` far
/// more often than it hands back anything a viewer could choose between, so the
/// language and codec from `getMediaInfo` are folded in beside the description
/// — see [trackLabel].
///
/// FOCUS lands once, on open, on the row that is active *then*: Flutter applies
/// an autofocus only while the scope has no focused child, so a value that
/// arrives after the first build - fresh media before its first snapshot -
/// moves the tick and leaves focus where it landed. A row that autofocuses on
/// a later rebuild is therefore harmless, and there is no bookkeeping for it.
///
/// That row also has to be *on screen*, and on a remux carrying a dozen
/// subtitle tracks it is not: a lazily-inflated list only runs its builder for
/// the rows near the top, so an `autofocus` twenty rows down never fires and
/// nothing in the panel claims focus at all. Both lists therefore go through
/// [PanelAnchoredList], like Sources, Episodes and Files, which seeds the
/// opening offset from the anchor, centres it against real geometry a frame
/// later and rescues focus into the list if no row took it. The tab's job is
/// to say which flattened child index the anchor is - see `_list`.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../domain/subtitle_search_target.dart';
import '../player_value_selector.dart';
import '../vlc_subtitle_search_sheet.dart';
import 'player_anchored_list.dart';
import 'player_panel_labels.dart';
import 'player_panel_row.dart';

/// Which list a tab is showing. The two differ by more than a title: only
/// subtitles have an Off and two ways to add a track from outside.
enum PlayerTrackKind { audio, subtitle }

/// How far one press of a delay stepper moves. A tenth of a second is the
/// finest a viewer can judge against the picture; the same step serves audio
/// and subtitle delay alike.
const Duration kSubtitleDelayStep = Duration(milliseconds: 100);

/// How far a *held* key moves per repeat. Half a second is the largest step
/// that cannot overshoot a badly muxed track in one go, and at a remote's
/// repeat rate it crosses two seconds in a lean rather than twenty presses.
const Duration kSubtitleDelayCoarseStep = Duration(milliseconds: 500);

/// The delay step a [PanelStep] asks for.
Duration delayStepFor(PanelStep step) => switch (step) {
  PanelStep.fine => kSubtitleDelayStep,
  PanelStep.coarse => kSubtitleDelayCoarseStep,
};

/// The stepper's read-out for a delay: whole milliseconds under a second
/// (`+100ms`, `-500ms`), one decimal of seconds from there (`+1.5s`). Always
/// signed, so `+0ms` reads as a state and not a blank.
String delayLabel(Duration delay) {
  final ms = delay.inMilliseconds;
  final sign = ms < 0 ? '-' : '+';
  final magnitude = ms.abs();
  if (magnitude < 1000) return '$sign${magnitude}ms';
  return '$sign${(magnitude / 1000).toStringAsFixed(1)}s';
}

class PlayerTracksTab extends StatelessWidget {
  const PlayerTracksTab({
    required this.controller,
    required this.kind,
    required this.tracks,
    required this.trackInfo,
    required this.onTracksChanged,
    this.target,
    this.isTv = false,
    this.autofocus = false,
    super.key,
  });

  final VlcPlayerController controller;
  final PlayerTrackKind kind;

  /// The engine's own descriptions, in the engine's own order.
  final List<VlcTrackDescription> tracks;

  /// `getMediaInfo`'s view of the same tracks, which carries the codec and
  /// channel count the descriptions lack. Correlated by position because that
  /// is the only correlation libVLC offers; a short list simply means the tail
  /// rows show no detail.
  final List<VlcMediaTrackInfo> trackInfo;

  /// Asks the panel to read both track lists from the engine again.
  ///
  /// Not fired after an add, which is the one moment it looks due. libVLC 3's
  /// add-slave is *queued* to the input thread: `addSubtitle` returns once the
  /// request is posted, not once the ES exists, so a list read in the same
  /// turn is still the pre-add one - the file the viewer just picked missing
  /// from it, nothing ticked - while the subtitle is already on its way to the
  /// screen. Publishing that as the engine's answer would also re-anchor the
  /// list and the D-pad focus on it ([PanelAnchoredList] re-centres on every
  /// reload), so the panel would land on the wrong row and stay there.
  ///
  /// The reload waits for the engine to say so instead. Every native moves
  /// `trackRevision` when the ES actually lands - ESAdded on Darwin and
  /// Android, the next poll on Windows and Linux - and the panel re-reads on
  /// that revision without being asked (player_panel.dart, `_onEngine`), which
  /// re-anchors on the side-car that is by then playing.
  ///
  /// What is left for this callback is Retry - the manual fallback for an
  /// engine that never said - and a refused set, which means the list on
  /// screen is out of date (see `_setTrack`).
  final VoidCallback onTracksChanged;

  /// What the online search is about: the screen's title, ids and episode.
  /// Null for media the catalogue knows nothing of, where the engine's own
  /// metadata seeds a title-only search instead.
  final SubtitleSearchTarget? target;

  final bool isTv;
  final bool autofocus;

  bool get _isAudio => kind == PlayerTrackKind.audio;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // libVLC's own `Disable` pseudo-track. Subtitles get a real Off row below
    // and audio has no use for one, so it is never a row of its own.
    final listed = tracks.where((track) => track.id >= 0).toList();

    // The active id and the revision are the only two things in the value
    // this list draws from; a position tick every 250 ms is not a rebuild.
    return PlayerValueSelector<(int?, int)>(
      controller: controller,
      selector: (value) => (
        _isAudio ? value.activeAudioTrackId : value.activeSubtitleTrackId,
        value.trackRevision,
      ),
      builder: (context, selected) => _list(context, l10n, listed, selected.$1),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    List<VlcTrackDescription> listed,
    int? active,
  ) {
    // Focus has to land somewhere. The engine says which track is on, and
    // that row takes it; when it names nothing (no ES yet, subtitles off) it
    // is Off for subtitles and the first row for audio - and when it names a
    // track the list has not caught up with, the same fallback rather than
    // nowhere at all. The tick is stricter: it follows the engine alone.
    final known = active != null && listed.any((track) => track.id == active);

    // The same three answers as positions in the flattened child list, because
    // that is what [PanelAnchoredList] scrolls to. Only subtitles have an Off
    // row ahead of the tracks, and an empty list puts a note where they were.
    final leading = _isAudio ? 0 : 1;
    final retryIndex = leading + (listed.isEmpty ? 1 : listed.length);
    final anchor = known
        ? leading + listed.indexWhere((track) => track.id == active)
        : (_isAudio ? (listed.isEmpty ? retryIndex : 0) : 0);

    final children = <Widget>[
      if (!_isAudio)
        PanelRow(
          label: l10n.off,
          icon: Icons.subtitles_off_outlined,
          selected: active == null,
          autofocus: autofocus && anchor == 0,
          onTap: () =>
              unawaited(_setTrack(context, controller.disableSubtitle)),
        ),
      if (listed.isEmpty)
        PanelEmpty(
          text: _isAudio ? l10n.noAudioTracksReported : l10n.noSubtitlesFound,
        )
      else
        for (final (index, track) in listed.indexed)
          PanelRow(
            label: trackLabel(track, _infoFor(index), l10n),
            detail: trackDetail(_infoFor(index)),
            selected: active == track.id,
            autofocus: autofocus && anchor == leading + index,
            onTap: () => unawaited(
              _setTrack(
                context,
                () => _isAudio
                    ? controller.setAudioTrack(track.id)
                    : controller.setSubtitleTrack(track.id),
              ),
            ),
          ),
      // Tracks can arrive after the panel opened - a side-car still being
      // fetched, a stream that has not announced its audio yet. The panel
      // re-reads the list when the engine's revision moves; this is the
      // manual fallback for an engine that did not say. It is also the only
      // row an empty Audio tab has, so it takes focus there.
      PanelRow(
        label: l10n.retry,
        icon: Icons.refresh_rounded,
        autofocus: autofocus && anchor == retryIndex,
        onTap: onTracksChanged,
      ),
      if (_isAudio)
        ..._audioExtras(l10n)
      else
        ..._subtitleExtras(context, l10n),
    ];

    // Building the widget objects eagerly is what this list already did and
    // costs nothing; handing them to the builder keeps the *elements* lazy,
    // which is the whole reason the anchor has to be scrolled to at all.
    return PanelAnchoredList(
      anchorIndex: anchor,
      // A one-line row is ~46 px and one carrying a codec detail ~60; the
      // middle keeps the anchor inside the viewport's 800 px cache for far
      // longer a list than either end would, and the frame-one centring
      // corrects it against the row's real geometry anyway.
      estimatedRowExtent: 53,
      autofocus: autofocus,
      itemCount: children.length,
      itemBuilder: (context, index) => children[index],
    );
  }

  VlcMediaTrackInfo? _infoFor(int index) =>
      index < trackInfo.length ? trackInfo[index] : null;

  /// Runs the engine call behind a row tap - a set, or Off.
  ///
  /// Nothing in this tab is optimistic, so a refusal needs no rollback: the
  /// tick is read off the engine's snapshot and never moved. What it does
  /// need is somewhere to *land*. A row's `onTap` is unawaited, so a bare
  /// `controller.setAudioTrack(id)` hands its failure to the zone, and the app
  /// installs no `PlatformDispatcher.onError`: a `track_not_found` - what
  /// Android returns when `setAudioTrack` comes back false, and what the
  /// Darwin guards raise - would be a console trace and nothing else.
  ///
  /// A refusal also *means* something. The id came from a list read once and
  /// held since; the engine refusing it says the list has moved on - a stream
  /// renegotiated, a language dropped. So the answer is to read it again: the
  /// dead row goes, the tick stays on whatever is really playing, and the
  /// viewer is not left pressing a row that cannot do anything.
  Future<void> _setTrack(
    BuildContext context,
    Future<void> Function() call,
  ) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // The panel can be closed, or the list already re-read under us, while
      // the call is in flight; a reload then belongs to nobody.
      if (context.mounted) onTracksChanged();
    }
  }

  /// Runs a delay call. Same absorption as [_setTrack] and for the same
  /// reason - the stepper's handlers are unawaited - but no reload: the
  /// stepper reads `value.audioDelay`/`value.subtitleDelay`, so a refused
  /// delay is simply a read-out that does not move, and no track list is
  /// stale because of it.
  Future<void> _step(Future<void> Function() call) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // Absorbed on purpose: see above.
    }
  }

  /// The one runtime adjustment libVLC exposes for audio: a delay against the
  /// picture, for a stream muxed out of step.
  List<Widget> _audioExtras(AppLocalizations l10n) {
    return <Widget>[
      PanelSubheader(title: l10n.audioDelay),
      _delayStepper(
        label: l10n.audioDelay,
        select: (value) => value.audioDelay,
        apply: controller.setAudioDelay,
      ),
    ];
  }

  /// The two ways a subtitle the stream does not carry gets into the engine,
  /// and the one runtime adjustment libVLC genuinely exposes.
  ///
  /// Both entry points end at `addSubtitle`, which makes the file a real track,
  /// so neither needs anywhere to put its result: it is simply in the list
  /// above the next time the list is read.
  List<Widget> _subtitleExtras(BuildContext context, AppLocalizations l10n) {
    return <Widget>[
      PanelSubheader(title: l10n.subtitleOptions),
      PanelRow(
        label: l10n.loadSubtitleFile,
        icon: Icons.file_open_outlined,
        onTap: () => unawaited(_loadFromDevice()),
      ),
      PanelRow(
        label: l10n.searchSubtitlesOnline,
        icon: Icons.search_rounded,
        onTap: () => unawaited(_searchOnline(context)),
      ),
      _delayStepper(
        label: l10n.subtitleDelay,
        select: (value) => value.subtitleDelay,
        apply: controller.setSubtitleDelay,
      ),
    ];
  }

  /// A delay stepper that follows the engine's own value - the natives echo
  /// a delay on the next snapshot - and rebuilds on that alone, not on every
  /// position tick. Select resets, when there is anything to reset.
  Widget _delayStepper({
    required String label,
    required Duration Function(VlcPlayerValue value) select,
    required Future<void> Function(Duration delay) apply,
  }) {
    return PlayerValueSelector<Duration>(
      controller: controller,
      selector: select,
      builder: (context, delay) => PanelStepperRow(
        label: label,
        value: delayLabel(delay),
        onDecrease: (step) =>
            unawaited(_step(() => apply(delay - delayStepFor(step)))),
        onIncrease: (step) =>
            unawaited(_step(() => apply(delay + delayStepFor(step)))),
        onReset: delay == Duration.zero
            ? null
            : () => unawaited(_step(() => apply(Duration.zero))),
      ),
    );
  }

  Future<void> _loadFromDevice() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      await controller.addSubtitle(Uri.file(path));
    } on VlcPlayerException catch (_) {
      // A file the engine will not take. Absorbed like every other engine
      // call here (see [_setTrack]): the handler is unawaited, the tab shows
      // engine truth either way, and the list is about to say the track is
      // not there - which is the honest answer.
    }
    // Deliberately no reload here - see the note on [onTracksChanged].
  }

  Future<void> _searchOnline(BuildContext context) async {
    final seed = await _searchSeed();
    if (!context.mounted) return;
    // The panel stays up either way: a viewer who backed out of the search
    // still wants the track list they opened it from. What the sheet returns
    // - whether it downloaded and added one - is not acted on: the sheet ends
    // at the same queued `addSubtitle`, so re-reading on its word has exactly
    // the problem described on [onTracksChanged].
    await VlcSubtitleSearchSheet.show(
      context,
      controller,
      target: seed,
      isTv: isTv,
    );
  }

  /// The screen's target when it has one; otherwise the engine's title alone,
  /// so a local file keeps its filename as the seed and nothing fires on open.
  Future<SubtitleSearchTarget?> _searchSeed() async {
    final given = target;
    if (given != null) return given;
    try {
      final title = (await controller.getMediaInfo()).title;
      return SubtitleSearchTarget(title: title ?? '');
    } catch (_) {
      // A seed is a convenience; an engine that will not answer is not a
      // reason to refuse to open the search.
      return null;
    }
  }
}
