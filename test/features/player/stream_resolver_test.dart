import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/library/presentation/history_provider.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

/// A provider reader backed by a fixed table, so the resolver can be exercised
/// without a container. Reading anything not listed is a failure rather than a
/// null, which keeps the tests honest about what the resolver actually touches.
ProviderReader readerOf(List<(Object, Object?)> entries) {
  return <T>(ProviderListenable<T> provider) {
    for (final (key, value) in entries) {
      if (identical(key, provider)) return value as T;
    }
    throw StateError('resolver read an unstubbed provider: $provider');
  };
}

MultimediaItem itemWith({String? provider}) => MultimediaItem(
  title: 'Test Movie',
  url: 'https://example.com/title/1',
  posterUrl: '',
  provider: provider,
);

StreamResult streamAt(String url, String source) =>
    StreamResult(url: url, source: source, providerName: 'Plugin');

void main() {
  final defaults = <(Object, Object?)>[
    (activeProviderProvider, null),
    (playerSettingsProvider, const AsyncValue<PlayerSettings>.data(
      PlayerSettings(),
    )),
    (watchHistoryProvider, const <HistoryItem>[]),
  ];

  group('resolvePlayback', () {
    // The bug this whole file exists for: PlayerRouteExtra.videoUrl is a plugin
    // resolution token, and plugins are free to make it a JSON array. Phase 5
    // called Uri.parse on it and threw FormatException before playback began.
    test('a videoUrl that is not a URI resolves via the streams', () async {
      const token =
          '[{"source":"https://cdn.example/480.mp4","quality":"480p"},'
          '{"source":"https://cdn.example/720.mp4","quality":"720p"}]';

      final resolved = await resolvePlayback(
        read: readerOf(defaults),
        item: itemWith(),
        videoUrl: token,
        preloadedStreams: [
          streamAt('https://cdn.example/480.mp4', '480p'),
          streamAt('https://cdn.example/720.mp4', '720p'),
        ],
        probeCandidates: 0,
      );

      expect(resolved.streams, hasLength(2));
      expect(resolved.selected.url, isNot(token));
      expect(Uri.parse(resolved.selected.url).hasScheme, isTrue);
    });

    test('local playback needs no provider and no plugin call', () async {
      final resolved = await resolvePlayback(
        read: readerOf(defaults),
        item: itemWith(provider: 'Local'),
        videoUrl: '/Users/me/Movies/movie.mkv',
        probeCandidates: 0,
      );

      expect(resolved.streams, hasLength(1));
      expect(resolved.selected.url, '/Users/me/Movies/movie.mkv');
      expect(resolved.selected.source, 'Video');
    });

    test('a torrent resolves to a torrent stream rather than a plugin call',
        () async {
      final resolved = await resolvePlayback(
        read: readerOf(defaults),
        item: itemWith(),
        videoUrl: 'magnet:?xt=urn:btih:abc',
        probeCandidates: 0,
      );

      expect(resolved.selected.source, 'Torrent');
    });

    test('no provider and nothing preloaded fails with a message', () async {
      expect(
        () => resolvePlayback(
          read: readerOf(defaults),
          item: itemWith(),
          videoUrl: 'https://example.com/episode/1',
          probeCandidates: 0,
        ),
        throwsA(
          isA<StreamResolutionException>().having(
            (e) => e.message,
            'message',
            'No provider selected.',
          ),
        ),
      );
    });
  });

  // The probe is a parallel race that used to surface nothing at all while it
  // ran, so a five-source title spent the whole health check behind one
  // undifferentiated spinner. These callbacks are what the player narrates.
  group('probe reporting', () {
    /// A bare path is healthy without a socket; a schemeless token is refused
    /// without one either. Between them the whole probe runs offline.
    List<StreamResult> candidatesWithHealthyMiddle() => [
      streamAt('nothing-here-a', '1080p'),
      streamAt('/sources/b.mkv', '720p'),
      streamAt('nothing-here-c', '480p'),
    ];

    test('every candidate is announced before any of them settles', () async {
      final events = <String>[];
      List<StreamResult>? candidates;

      final resolved = await resolvePlayback(
        read: readerOf(defaults),
        item: itemWith(),
        videoUrl: 'https://example.com/episode/1',
        preloadedStreams: candidatesWithHealthyMiddle(),
        probeCandidates: 3,
        onCandidates: (streams) {
          candidates = streams;
          events.add('candidates:${streams.length}');
        },
        onProbe: (index, outcome) => events.add('$index:${outcome.name}'),
      );

      expect(candidates, hasLength(3));
      // The order matters as much as the contents: the list has to be known
      // before an index into it means anything, and the dispatch order is the
      // failover order.
      expect(events.take(4).toList(), <String>[
        'candidates:3',
        '0:trying',
        '1:trying',
        '2:trying',
      ]);

      final healthy = candidates!.indexWhere((s) => s.url == '/sources/b.mkv');
      expect(events, contains('$healthy:healthy'));
      for (var i = 0; i < candidates!.length; i++) {
        if (i == healthy) continue;
        expect(events, contains('$i:unhealthy'));
      }
      expect(resolved.index, healthy);
    });

    test(
      'the candidate list is reported even when nothing is probed',
      () async {
        List<StreamResult>? candidates;
        await resolvePlayback(
          read: readerOf(defaults),
          item: itemWith(provider: 'Local'),
          videoUrl: '/Users/me/Movies/movie.mkv',
          probeCandidates: 0,
          onCandidates: (streams) => candidates = streams,
        );

        expect(
          candidates,
          hasLength(1),
          reason: 'a direct stream is still a source the viewer can be shown',
        );
      },
    );

    // Skip during the probe means "stop waiting", not "give up": whatever the
    // race has actually proved by then is better than another three seconds of
    // spinner.
    test('skipping the probe takes the best candidate known so far', () async {
      final settled = <int>[];
      final resolved = await resolvePlayback(
        read: readerOf(defaults),
        item: itemWith(),
        videoUrl: 'https://example.com/episode/1',
        preloadedStreams: candidatesWithHealthyMiddle(),
        probeCandidates: 3,
        onProbe: (index, outcome) {
          if (outcome != ProbeOutcome.trying) settled.add(index);
        },
        stopProbing: Future<void>.value(),
      );

      expect(
        resolved.index,
        0,
        reason: 'nothing had been proved yet, so the preferred source stands',
      );
      expect(
        settled,
        isNotEmpty,
        reason: 'the probes in flight still report what they find',
      );
    });
  });

  group('isLiveSource', () {
    MultimediaItem itemOf(MultimediaContentType type) => MultimediaItem(
      title: 'T',
      url: 'https://example.com/t',
      posterUrl: '',
      contentType: type,
    );

    test('a livestream item is live whatever the url looks like', () {
      expect(
        isLiveSource(
          itemOf(MultimediaContentType.livestream),
          'https://cdn.example/channel.m3u8',
        ),
        isTrue,
      );
    });

    test('live protocols are live even on a movie item', () {
      for (final url in const [
        'rtmp://a/b',
        'rtsp://a/b',
        'mms://a/b',
        'udp://a/b',
        'rtp://a/b',
      ]) {
        expect(isLiveSource(itemOf(MultimediaContentType.movie), url), isTrue,
            reason: url);
      }
    });

    test('a plain http movie is not live', () {
      expect(
        isLiveSource(itemOf(MultimediaContentType.movie), 'https://a/b.mp4'),
        isFalse,
      );
    });

    // However the item is labelled, these are files and seek normally.
    test('torrents and local files are never live', () {
      final live = itemOf(MultimediaContentType.livestream);
      expect(isLiveSource(live, 'magnet:?xt=urn:btih:abc'), isFalse);
      expect(isLiveSource(live, 'https://a/b.torrent'), isFalse);
      expect(isLiveSource(live, '/Users/me/Movies/a.mkv'), isFalse);
    });

    test('an empty url falls back to the content type', () {
      expect(isLiveSource(itemOf(MultimediaContentType.livestream), ''), isTrue);
      expect(isLiveSource(itemOf(MultimediaContentType.movie), ''), isFalse);
    });

    // Plugins routinely type an IPTV channel as `movie`, and believing them
    // costs live caching, the reconnect loop and a sane progress record.
    test('iptv url shapes are live even on a movie item', () {
      for (final url in const [
        'https://portal.example/live/user/pass/1234.m3u8',
        'https://portal.example/iptv/channel/9.ts',
        'https://edge.example/hls/stream.m3u8',
        'https://edge.example/app/chunklist_w1234567.m3u8',
        'https://portal.example/get.php?username=u&password=p&type=m3u8',
        'https://portal.example/get.php?username=u&password=p&output=m3u8',
      ]) {
        expect(
          isLiveSource(itemOf(MultimediaContentType.movie), url),
          isTrue,
          reason: url,
        );
      }
    });

    test('the url shapes are matched case-insensitively', () {
      expect(
        isLiveSource(
          itemOf(MultimediaContentType.movie),
          'https://Portal.example/LIVE/user/pass/1234.M3U8',
        ),
        isTrue,
      );
    });

    // The whole point of keeping the patterns narrow: an on-demand HLS ladder
    // is also .m3u8, and calling it live would break seeking and resume.
    test('ordinary hls vod stays vod', () {
      for (final url in const [
        'https://cdn.example/movies/inception/master.m3u8',
        'https://cdn.example/assets/1234/index.m3u8',
        'https://cdn.example/assets/1234/playlist.m3u8',
        'https://cdn.example/assets/1234/720p/prog_index.m3u8',
        'https://cdn.example/title.m3u8',
        'https://cdn.example/deliver.mp4?output=mp4',
      ]) {
        expect(
          isLiveSource(itemOf(MultimediaContentType.movie), url),
          isFalse,
          reason: url,
        );
      }
    });

    // A URL that names itself on-demand beats a shape we only guessed at:
    // Xtream serves VOD from /movie/ and /series/, and Wowza cuts on-demand
    // HLS into chunklists under /vod/.
    test('an explicit vod path outranks a live-looking url shape', () {
      for (final url in const [
        'https://host/vod/_definst_/mp4:a.mp4/chunklist_w1.m3u8',
        'https://portal.example/movie/user/pass/4567.mkv',
        'https://portal.example/series/user/pass/8910.mp4',
        'https://cdn.example/vod/hls/stream.m3u8',
      ]) {
        expect(
          isLiveSource(itemOf(MultimediaContentType.movie), url),
          isFalse,
          reason: url,
        );
      }
    });

    // The veto is a tie-breaker between guesses, not a licence to override the
    // plugin's own metadata.
    test('an explicit vod path does not override a livestream item', () {
      expect(
        isLiveSource(
          itemOf(MultimediaContentType.livestream),
          'https://cdn.example/vod/hls/stream.m3u8',
        ),
        isTrue,
      );
    });

    test('a local iptv-looking path is still vod', () {
      expect(
        isLiveSource(
          itemOf(MultimediaContentType.movie),
          '/Users/me/Movies/live/a.m3u8',
        ),
        isFalse,
      );
    });
  });

  group('isTorrentSource', () {
    StreamResult s(String url, String source) =>
        StreamResult(url: url, source: source);

    test('magnet links and .torrent files need the torrent service', () {
      expect(isTorrentSource(s('magnet:?xt=urn:btih:abc', 'Torrent')), isTrue);
      expect(isTorrentSource(s('https://a/b.torrent', 'Torrent')), isTrue);
    });

    test('an ordinary http stream does not', () {
      expect(isTorrentSource(s('https://cdn.example/a.mp4', '1080p')), isFalse);
    });

    // A bare absolute path is normally a local file; only a torrent-sourced
    // one is a seeded file the service already knows about.
    test('a bare path counts only when the source says Torrent', () {
      expect(isTorrentSource(s('/downloads/movie.mkv', 'Torrent')), isTrue);
      expect(isTorrentSource(s('/Users/me/Movies/a.mkv', 'Video')), isFalse);
    });
  });
}
