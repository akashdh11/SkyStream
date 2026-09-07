import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../domain/entity/subtitle_model.dart';
import '../../domain/subtitle_search_target.dart';
import '../subtitle_search_provider.dart';

/// Online subtitle search, reachable again.
///
/// [SubtitleSearch] has been in the tree the whole time — three providers,
/// cancellation, ZIP/GZIP extraction on a worker isolate — with nothing but its
/// own generated file importing it. The old side panel was its only door and
/// went out with the media_kit player. This is the replacement door, and
/// nothing more: the search itself is used exactly as designed.
///
/// What the door is handed is a [SubtitleSearchTarget]: the title the player
/// is showing and, when the catalogue knew them, its IMDb/TMDb id and the
/// episode. With an id the sheet searches the moment it opens - zero presses
/// on a remote - because an id match is exact and a title match is a guess.
/// The field still shows the title, and the moment the viewer edits it the
/// next search is by that text alone: every provider prefers an id over the
/// query when both are sent, so an edited title with the ids still attached
/// would be silently ignored. Restoring the exact title turns the ids back on.
///
/// A result is handed to the engine as an ordinary side-car, so once it is
/// added it is just another entry in the Subtitles tab's list with a libVLC id
/// like any other. No parallel "external subtitle" bookkeeping comes back.
class VlcSubtitleSearchSheet extends ConsumerStatefulWidget {
  const VlcSubtitleSearchSheet({
    required this.controller,
    this.target,
    this.isTv = false,
    super.key,
  });

  final VlcPlayerController controller;

  /// What the player already knows the viewer is watching. The title seeds
  /// the field; an id, when there is one, makes the search fire on open.
  final SubtitleSearchTarget? target;

  /// On a D-pad, focus starts on the search button when the field is seeded -
  /// with an id that is the Retry target while results load, without one it
  /// *is* the one button press - and on the field when there is nothing to
  /// search for yet.
  final bool isTv;

  /// Resolves to `true` when a subtitle was added, so the caller can close
  /// itself instead of dropping the viewer back into a stale track list.
  static Future<bool?> show(
    BuildContext context,
    VlcPlayerController controller, {
    SubtitleSearchTarget? target,
    bool isTv = false,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      builder: (_) => VlcSubtitleSearchSheet(
        controller: controller,
        target: target,
        isTv: isTv,
      ),
    );
  }

  @override
  ConsumerState<VlcSubtitleSearchSheet> createState() =>
      _VlcSubtitleSearchSheetState();
}

class _VlcSubtitleSearchSheetState
    extends ConsumerState<VlcSubtitleSearchSheet> {
  late final TextEditingController _query = TextEditingController(
    text: widget.target?.title ?? '',
  );

  /// Whether the next search sends the target's ids. On while the field
  /// still reads the target's own title; off the moment it says anything
  /// else, so the viewer's words are what gets searched.
  bool _idSearch = false;

  /// Set while a result is being fetched and unpacked. Downloads take seconds
  /// over a slow link, and a second tap would race the first.
  bool _downloading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _idSearch = widget.target?.hasId ?? false;
    // An id is worth a search nobody asked for; a bare title is not - a local
    // file's filename would otherwise hit the network on every open. A search
    // already in flight (the notifier outlives this sheet) is left to finish.
    if (_idSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(subtitleSearchProvider).isLoading) return;
        _search();
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _onEdited(String text) {
    final target = widget.target;
    _idSearch =
        target != null && target.hasId && text.trim() == target.title.trim();
  }

  void _search() {
    final query = _query.text.trim();
    final target = widget.target;
    final byId = _idSearch && target != null;
    if (query.isEmpty && !byId) return;
    setState(() => _error = null);
    // Season and episode ride along in both modes: a title search for a
    // series is still a search for *this* episode's file.
    ref
        .read(subtitleSearchProvider.notifier)
        .search(
          query: query,
          imdbId: byId ? target.imdbId : null,
          tmdbId: byId ? target.tmdbId : null,
          season: target?.season,
          episode: target?.episode,
          language: ref.read(subtitleLanguageProvider),
        );
  }

  Future<void> _apply(OnlineSubtitle subtitle) async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    final path = await ref
        .read(subtitleSearchProvider.notifier)
        .downloadAndPrepare(subtitle);
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _downloading = false;
        _error = AppLocalizations.of(context)!.subtitleDownloadFailed;
      });
      return;
    }
    // The engine refuses side-cars for reasons the sheet cannot see - a
    // disposed controller, a URI the platform will not take, an addSlave that
    // comes back false. Unguarded, the throw escapes an unawaited `onTap`
    // future and `_downloading` stays true forever: the progress bar never
    // stops, every result is `enabled: false` (so on a remote the whole list
    // leaves focus traversal) and nothing says why. Release the state and say
    // it failed, exactly as the empty-path branch above does.
    try {
      await widget.controller.addSubtitle(Uri.file(path));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = AppLocalizations.of(context)!.subtitleDownloadFailed;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _pickLanguage() async {
    final current = ref.read(subtitleLanguageProvider);
    final entries = subtitleLanguages.entries.toList();
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1D1D1D),
        surfaceTintColor: Colors.transparent,
        title: Text(
          AppLocalizations.of(context)!.subtitleLanguage,
          style: const TextStyle(color: Colors.white),
        ),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in entries)
                  ListTile(
                    dense: true,
                    autofocus: widget.isTv && entry.value == current,
                    // The radio is a picture of the tile's state, not a second
                    // control: left focusable it doubles every row's D-pad
                    // stops across forty languages.
                    leading: ExcludeFocus(
                      child: Radio<String>(value: entry.value),
                    ),
                    title: Text(
                      entry.key,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () => Navigator.of(context).pop(entry.value),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    ref.read(subtitleLanguageProvider.notifier).set(chosen);
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final language = ref.watch(subtitleLanguageProvider);
    final results = ref.watch(subtitleSearchProvider);
    // Read beside the state it describes: the notifier assigns the mode
    // before every state write, so the pair is always of the same pass.
    final mode = ref.watch(subtitleSearchProvider.notifier).lastMode;
    final seeded = _query.text.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        // The field pulls up the on-screen keyboard on a phone; without this
        // the results and the field itself end up behind it.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: widget.isTv && !seeded,
                      style: const TextStyle(color: Colors.white),
                      textInputAction: TextInputAction.search,
                      onChanged: _onEdited,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        labelText: l10n.searchOnlineSubtitles,
                        labelStyle: const TextStyle(color: Colors.white54),
                        enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search, color: Colors.white),
                    tooltip: l10n.search,
                    autofocus: widget.isTv && seeded,
                    onPressed: _search,
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.translate, color: Colors.white70),
              title: Text(
                l10n.language,
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                _languageName(language),
                style: const TextStyle(color: Colors.white54),
              ),
              onTap: _pickLanguage,
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  error,
                  style: const TextStyle(color: Color(0xFFEF9A9A)),
                ),
              ),
            if (_downloading) const LinearProgressIndicator(minHeight: 2),
            const Divider(height: 1, color: Colors.white12),
            Flexible(child: _results(l10n, results, mode)),
          ],
        ),
      ),
    );
  }

  Widget _results(
    AppLocalizations l10n,
    AsyncValue<List<OnlineSubtitle>?> results,
    SubtitleSearchMode mode,
  ) {
    return switch (results) {
      AsyncLoading() => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      // The search reports per-provider failures through its own logging and
      // still resolves, so an error here is the provider list itself failing
      // to build - worth showing rather than swallowing.
      AsyncError(:final error) => _note(l10n.subtitleSearchFailed('$error')),
      AsyncData(value: null) => _note(l10n.subtitleSearchPrompt),
      // Empty is empty. Searching needs no account: OpenSubtitles runs on a
      // bundled key (subtitle_providers.dart `_defaultApiKey`) and SubSource
      // takes its keyless path, so a fresh install really did search - only
      // SubDL sits out without a key. Reading "no account is set up" off empty
      // settings blamed the viewer's configuration for the ordinary answer
      // and hid the one piece of advice that helps.
      AsyncData(value: final found) when found!.isEmpty => _note(
        l10n.noSubtitlesFoundTryAnother,
      ),
      AsyncData(value: final found) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // These are not what was asked for: the exact match missed and the
          // notifier widened the search on its own. Said once, above the
          // list, as text - not a row a remote has to step over.
          if (_fallbackNote(l10n, mode) case final note?) _note(note),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: found!.length,
              itemBuilder: (context, index) {
                final subtitle = found[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    subtitle.name,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${subtitle.source} · ${subtitle.language}'
                    '${subtitle.isHearingImpaired ? ' · SDH' : ''}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  enabled: !_downloading,
                  onTap: () => _apply(subtitle),
                );
              },
            ),
          ),
        ],
      ),
    };
  }

  /// What to say above results the notifier widened to on its own, or null
  /// when they are what was asked for.
  ///
  /// The two widenings are different news and cannot share a string. An id
  /// that missed leaves title matches for *this* episode, and that is all
  /// [AppLocalizations.subtitleSearchTitleFallback] claims. The season pass
  /// is reachable with no id ever sent - `_nextMode` takes any non-season
  /// mode with a season and an episode - so the id wording would be simply
  /// false there; worse, what it leaves out is the thing that matters, that
  /// the list now spans the whole season and the viewer has to find their own
  /// episode in it or end up one to nine episodes out of sync. An exhaustive
  /// switch, so a new mode cannot silently inherit either note.
  static String? _fallbackNote(
    AppLocalizations l10n,
    SubtitleSearchMode mode,
  ) => switch (mode) {
    SubtitleSearchMode.byId || SubtitleSearchMode.byTitle => null,
    SubtitleSearchMode.byTitleAfterIdMiss => l10n.subtitleSearchTitleFallback,
    SubtitleSearchMode.bySeasonAfterEpisodeMiss =>
      l10n.subtitleSearchSeasonFallback,
  };

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    child: Text(text, style: const TextStyle(color: Colors.white38)),
  );

  String _languageName(String code) {
    for (final entry in subtitleLanguages.entries) {
      if (entry.value == code) return entry.key;
    }
    return code;
  }
}
