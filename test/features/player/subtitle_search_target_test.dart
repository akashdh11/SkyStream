import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/subtitle_search_target.dart';

MultimediaItem _item({
  String? imdbId,
  int? tmdbId,
  Map<String, String>? syncData,
}) => MultimediaItem(
  title: 'The Show',
  url: 'https://example.test/show',
  posterUrl: '',
  imdbId: imdbId,
  tmdbId: tmdbId,
  syncData: syncData,
);

Episode _episode({int season = 0, int episode = 0}) => Episode(
  name: 'Ep',
  url: 'https://example.test/show/ep',
  season: season,
  episode: episode,
);

void main() {
  group('SubtitleSearchTarget.of imdb precedence', () {
    test('item.imdbId wins over both syncData keys', () {
      final target = SubtitleSearchTarget.of(
        _item(
          imdbId: 'tt0000001',
          syncData: {'imdbId': 'tt0000002', 'imdb_id': 'tt0000003'},
        ),
        null,
      );
      expect(target.imdbId, 'tt0000001');
    });

    test("syncData['imdbId'] wins over syncData['imdb_id']", () {
      final target = SubtitleSearchTarget.of(
        _item(syncData: {'imdbId': 'tt0000002', 'imdb_id': 'tt0000003'}),
        null,
      );
      expect(target.imdbId, 'tt0000002');
    });

    test("syncData['imdb_id'] is the last resort", () {
      final target = SubtitleSearchTarget.of(
        _item(syncData: {'imdb_id': 'tt0000003'}),
        null,
      );
      expect(target.imdbId, 'tt0000003');
    });

    test('no id anywhere -> null and hasId false', () {
      final target = SubtitleSearchTarget.of(
        _item(syncData: {'tmdb': '42'}),
        null,
      );
      expect(target.imdbId, isNull);
      expect(target.tmdbId, isNull);
      expect(target.hasId, isFalse);
    });
  });

  group('SubtitleSearchTarget.of tt normalisation', () {
    test("'0111161' -> 'tt0111161'", () {
      expect(
        SubtitleSearchTarget.of(_item(imdbId: '0111161'), null).imdbId,
        'tt0111161',
      );
    });

    test("'tt0111161' unchanged", () {
      expect(
        SubtitleSearchTarget.of(_item(imdbId: 'tt0111161'), null).imdbId,
        'tt0111161',
      );
    });

    test('bare id from syncData is normalised too', () {
      expect(
        SubtitleSearchTarget.of(
          _item(syncData: {'imdb_id': '0111161'}),
          null,
        ).imdbId,
        'tt0111161',
      );
    });

    test('blank or whitespace id is null, not "tt"', () {
      expect(SubtitleSearchTarget.of(_item(imdbId: ''), null).imdbId, isNull);
      expect(
        SubtitleSearchTarget.of(_item(imdbId: '   '), null).imdbId,
        isNull,
      );
      expect(SubtitleSearchTarget.normalizeImdbId(null), isNull);
    });
  });

  group('SubtitleSearchTarget.of season / episode', () {
    test('episode null drops season and episode', () {
      final target = SubtitleSearchTarget.of(_item(imdbId: 'tt1'), null);
      expect(target.season, isNull);
      expect(target.episode, isNull);
      expect(target.hasEpisode, isFalse);
    });

    test('zero season / episode (Episode defaults) become null', () {
      final target = SubtitleSearchTarget.of(_item(), _episode());
      expect(target.season, isNull);
      expect(target.episode, isNull);
    });

    test('positive season and episode are carried through', () {
      final target = SubtitleSearchTarget.of(
        _item(),
        _episode(season: 2, episode: 5),
      );
      expect(target.season, 2);
      expect(target.episode, 5);
      expect(target.hasEpisode, isTrue);
    });

    test('a known season with an unknown episode keeps only the season', () {
      final target = SubtitleSearchTarget.of(_item(), _episode(season: 3));
      expect(target.season, 3);
      expect(target.episode, isNull);
      expect(target.hasEpisode, isFalse);
    });

    test('title stays the bare show title, never decorated', () {
      final target = SubtitleSearchTarget.of(
        _item(),
        _episode(season: 2, episode: 5),
      );
      expect(target.title, 'The Show');
    });
  });

  group('SubtitleSearchTarget ids', () {
    test('hasId is true with only a tmdbId', () {
      final target = SubtitleSearchTarget.of(_item(tmdbId: 1396), null);
      expect(target.tmdbId, 1396);
      expect(target.imdbId, isNull);
      expect(target.hasId, isTrue);
    });

    test('hasId is true with only an imdbId', () {
      expect(
        const SubtitleSearchTarget(title: 'x', imdbId: 'tt1').hasId,
        isTrue,
      );
    });

    test('value equality', () {
      const a = SubtitleSearchTarget(
        title: 'x',
        imdbId: 'tt1',
        tmdbId: 2,
        season: 1,
        episode: 3,
      );
      const b = SubtitleSearchTarget(
        title: 'x',
        imdbId: 'tt1',
        tmdbId: 2,
        season: 1,
        episode: 3,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(const SubtitleSearchTarget(title: 'x'))));
    });
  });
}
