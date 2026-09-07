import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Local mirror of the "Translation Coverage" step in `.github/workflows/ci.yml`.
///
/// CI reads `build/l10n_untranslated.json`, which only exists after
/// `flutter gen-l10n` has run; this test reads the ARB files directly so the
/// same rules hold on a fresh checkout and fail here, with the offending keys
/// named, before a push does. The two must stay in step: when the workflow's
/// `TOP_TIER` or `BACKLOG` change, change [_topTier] and [_backlog] too.
///
/// The rules, in the workflow's words:
///  * hi and kn are the founding, hand-authored locales and block a merge;
///    the other 39 arrived in one bulk import and only warn.
///  * A key some other locale has already translated is not shared backlog -
///    a top-tier locale missing it has fallen behind. That is why every new
///    string has to land in en, hi and kn in the same change, and why a hi-only
///    or kn-only translation trips the gate for the other one.
///  * The shared backlog may fall, never rise.
void main() {
  final Directory arbDir = Directory('lib/l10n');
  late final Map<String, Set<String>> keysByLocale = _readArbKeys(arbDir);

  test('hi and kn are missing the same keys', () {
    final Set<String> hiMissing = _missing(keysByLocale, 'hi');
    final Set<String> knMissing = _missing(keysByLocale, 'kn');
    expect(
      hiMissing,
      equals(knMissing),
      reason:
          'Translate into both top-tier locales in the same change.\n'
          'hi lacks but kn has: ${(hiMissing.difference(knMissing).toList()..sort()).join(', ')}\n'
          'kn lacks but hi has: ${(knMissing.difference(hiMissing).toList()..sort()).join(', ')}',
    );
  });

  test('top-tier locales are within the backlog ratchet', () {
    for (final String locale in _topTier) {
      final Set<String> missing = _missing(keysByLocale, locale);
      expect(
        missing.length,
        lessThanOrEqualTo(_backlog),
        reason:
            '$locale is missing ${missing.length} keys, above the $_backlog '
            'the backlog ratchet allows: ${(missing.toList()..sort()).join(', ')}',
      );
    }
  });

  test('top-tier locales are not behind any other locale', () {
    // Reproduces ci.yml's shared/behind split over the ARBs instead of the
    // gen-l10n report.
    final Iterable<Set<String>> allMissing = keysByLocale.keys
        .where((String locale) => locale != _template)
        .map((String locale) => _missing(keysByLocale, locale));
    final Set<String> shared = allMissing.reduce(
      (Set<String> a, Set<String> b) => a.intersection(b),
    );
    final Set<String> behind = allMissing
        .reduce((Set<String> a, Set<String> b) => a.union(b))
        .difference(shared);

    for (final String locale in _topTier) {
      final List<String> lagging = _missing(
        keysByLocale,
        locale,
      ).intersection(behind).toList()..sort();
      expect(
        lagging,
        isEmpty,
        reason:
            '$locale is missing ${lagging.length} key(s) other locales '
            'already have: ${lagging.join(', ')}',
      );
    }
  });

  test('every key the player consumes is present in en, hi and kn', () {
    for (final String locale in <String>[_template, ..._topTier]) {
      final Set<String> keys = keysByLocale[locale]!;
      final List<String> absent = _playerKeys
          .where((String key) => !keys.contains(key))
          .toList();
      expect(
        absent,
        isEmpty,
        reason: 'app_$locale.arb lacks: ${absent.join(', ')}',
      );
    }
  });

  test('the ARB template is the superset of every locale', () {
    // A key in a translation but not in en is dead weight gen-l10n ignores;
    // usually a typo in the key name that silently leaves the English in place.
    final Set<String> template = keysByLocale[_template]!;
    for (final MapEntry<String, Set<String>> entry in keysByLocale.entries) {
      final List<String> extra = entry.value.difference(template).toList()
        ..sort();
      expect(
        extra,
        isEmpty,
        reason:
            'app_${entry.key}.arb has keys en does not: ${extra.join(', ')}',
      );
    }
  });
}

/// Locale codes ci.yml treats as blocking (`TOP_TIER`).
const Set<String> _topTier = <String>{'hi', 'kn'};

/// Most keys a top-tier locale may lack (`BACKLOG`). Falls, never rises.
const int _backlog = 62;

const String _template = 'en';

/// Keys the Phase 2 player work reads; a rename or removal in en must show up
/// here rather than as a runtime English fallback in hi or kn.
const List<String> _playerKeys = <String>[
  'audioDelay',
  'subtitleSearchTitleFallback',
  'subtitleAccountsNotConfigured',
  'audioTracks',
  'episodes',
  'live',
  'off',
  'retry',
];

Set<String> _missing(Map<String, Set<String>> keysByLocale, String locale) {
  final Set<String>? keys = keysByLocale[locale];
  expect(keys, isNotNull, reason: 'no app_$locale.arb under lib/l10n');
  return keysByLocale[_template]!.difference(keys!);
}

/// Message keys per locale, `@@locale` and `@key` metadata dropped, keyed by
/// the locale suffix of the file name (`app_pt_BR.arb` -> `pt_BR`).
Map<String, Set<String>> _readArbKeys(Directory arbDir) {
  expect(
    arbDir.existsSync(),
    isTrue,
    reason: 'run this from the package root so lib/l10n resolves',
  );
  final RegExp name = RegExp(r'^app_(.+)\.arb$');
  final Map<String, Set<String>> result = <String, Set<String>>{};
  for (final FileSystemEntity entity in arbDir.listSync()) {
    if (entity is! File) continue;
    final RegExpMatch? match = name.firstMatch(entity.uri.pathSegments.last);
    if (match == null) continue;
    final Map<String, dynamic> arb =
        jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    result[match.group(1)!] = arb.keys
        .where((String key) => !key.startsWith('@'))
        .toSet();
  }
  expect(result, contains(_template));
  return result;
}
