import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';
import 'package:skystream/features/tracking/data/tracking_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'vlc_screen_harness.dart';

/// What the scrubber says on the real screen while the engine has not named a
/// length, and once it has.
///
/// The harness's default snapshot is `duration: 0, isSeekable: true`, which is
/// exactly what libVLC sends for the first beat of every VOD item - so until
/// this change every screen test was quietly rendering the LIVE pill over a
/// movie. The pill now needs a verdict: the app's, from the item and URL, or
/// the engine's, which arrives as `isLive: true` with `isSeekable: false`.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets(
    'a movie with no length yet reads --:--, then the clock, then LIVE only '
    'when the engine says so',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(
        tester,
        // A real length is what starts scrobbling, and the other screen
        // tests never send one; the tracker would otherwise read a sync
        // manager whose services are not stood up here.
        overrides: [
          syncManagerProvider.overrideWithValue(
            SyncManager(const <TrackingService>[]),
          ),
        ],
      );
      final l10n = await english();

      await sendFirstFrame(tester);
      expect(find.byType(VlcPlayerControls), findsOneWidget);
      expect(
        find.text(l10n.live),
        findsNothing,
        reason: 'a length that has not arrived is not a live verdict',
      );
      expect(find.text('0:01 / --:--'), findsOneWidget);

      await sendEvent(tester, snapshot(position: 1999, duration: 5400000));
      expect(find.text('0:01 / 1:30:00'), findsOneWidget);
      expect(find.text(l10n.live), findsNothing);

      await sendEvent(tester, <String, Object?>{
        ...snapshot(position: 2500),
        'isSeekable': false,
        'isLive': true,
      });
      expect(find.text(l10n.live), findsOneWidget);
      expect(find.textContaining('--:--'), findsNothing);

      // A playing controller holds the stall watchdog; leave it paused.
      await sendEvent(tester, snapshot(state: 'paused', position: 2500));
    },
  );
}
