import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';

void main() {
  group('stallActionFor', () {
    StallAction at(
      int seconds, {
      bool hadFrames = true,
      StallAction last = StallAction.none,
      Duration? recoverAfter,
    }) => stallActionFor(
      stalledFor: Duration(seconds: seconds),
      hadFrames: hadFrames,
      lastAction: last,
      recoverAfter: recoverAfter ?? kStallRecoverAfter,
    );

    test('healthy playback asks for nothing', () {
      expect(at(0), StallAction.none);
      expect(at(3), StallAction.none);
      expect(at(9), StallAction.none);
    });

    test('a source that was playing gets nudged first', () {
      expect(at(10), StallAction.nudge);
      expect(at(20), StallAction.nudge);
    });

    // The whole point of lastAction: the caller ticks once a second, so
    // without it a single stall would re-issue the same seek 15 times.
    test('each rung fires once per stall window', () {
      expect(at(12, last: StallAction.nudge), StallAction.none);
      expect(at(30, last: StallAction.recover), StallAction.none);
    });

    test('a nudge that did not help escalates to recovery', () {
      expect(at(25, last: StallAction.nudge), StallAction.recover);
    });

    // A device that slept through the ladder must not spend another 25
    // seconds walking it.
    test('a long freeze escalates straight past the nudge', () {
      expect(at(600), StallAction.recover);
    });

    group('before the first frame', () {
      test('there is nothing to nudge', () {
        expect(at(10, hadFrames: false), StallAction.none);
        expect(at(24, hadFrames: false), StallAction.none);
      });

      test('the deadline still abandons the source', () {
        expect(at(25, hadFrames: false), StallAction.recover);
      });

      test('a torrent gets minutes to seed, not seconds', () {
        expect(
          at(
            60,
            hadFrames: false,
            recoverAfter: kTorrentStallRecoverAfter,
          ),
          StallAction.none,
        );
        expect(
          at(
            181,
            hadFrames: false,
            recoverAfter: kTorrentStallRecoverAfter,
          ),
          StallAction.recover,
        );
      });
    });
  });

  group('nextFailoverIndex', () {
    test('walks forward from the current candidate', () {
      expect(nextFailoverIndex(from: 0, total: 3, tried: {0}), 1);
      expect(nextFailoverIndex(from: 1, total: 3, tried: {0, 1}), 2);
    });

    // The bug this exists for: _start opens the resolver's pick, which is
    // routinely not zero, so a forward-only walk can never reach 0 or 1.
    test('wraps past the end to the candidates before the first pick', () {
      expect(nextFailoverIndex(from: 2, total: 3, tried: {2}), 0);
      expect(nextFailoverIndex(from: 0, total: 3, tried: {2, 0}), 1);
    });

    test('skips candidates already tried', () {
      expect(nextFailoverIndex(from: 1, total: 5, tried: {1, 2, 3}), 4);
    });

    test('gives up once every candidate has had a turn', () {
      expect(nextFailoverIndex(from: 1, total: 3, tried: {0, 1, 2}), isNull);
      expect(nextFailoverIndex(from: 0, total: 1, tried: {0}), isNull);
    });

    test('visits every candidate exactly once and then stops', () {
      const total = 4;
      final tried = <int>{2}; // the resolver's pick, already open
      var current = 2;
      final walk = <int>[];
      while (true) {
        final next = nextFailoverIndex(
          from: current,
          total: total,
          tried: tried,
        );
        if (next == null) break;
        walk.add(next);
        tried.add(next);
        current = next;
      }
      expect(walk, <int>[3, 0, 1]);
    });

    test('an empty candidate list has no next', () {
      expect(nextFailoverIndex(from: 0, total: 0, tried: const <int>{}), isNull);
    });
  });
}
