import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/features/settings/presentation/widgets/subtitle_appearance_settings.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  group('labels', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('names an offered colour and falls back to hex for anything else', () {
      expect(subtitleColorLabel(l10n, 0xFFFFFFFF), 'White');
      expect(subtitleColorLabel(l10n, 0xFFFFEB3B), 'Yellow');
      expect(subtitleColorLabel(l10n, 0xFFFF8800), '#FF8800');
    });

    test('calls a zero-opacity background Off, whatever colour is stored', () {
      expect(
        subtitleBackgroundLabel(
          l10n,
          const PlayerSettings(
            subtitleBackgroundColor: 0xFF000000,
            subtitleBackgroundOpacity: 0,
          ),
        ),
        'Off',
      );
      expect(
        subtitleBackgroundLabel(
          l10n,
          const PlayerSettings(
            subtitleBackgroundColor: 0xFF000000,
            subtitleBackgroundOpacity: 0.75,
          ),
        ),
        'Black · 75%',
      );
    });

    test('the frame is the short edge, because playback is landscape', () {
      expect(subtitleFrameHeight(const Size(400, 900)), 400);
      expect(subtitleFrameHeight(const Size(1920, 1080)), 1080);
    });
  });

  group('SubtitlePreview', () {
    Future<void> pumpPreview(
      WidgetTester tester,
      PlayerSettings settings, {
      Size window = const Size(1920, 1080),
    }) {
      return tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: window),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SubtitlePreview(
                settings: settings,
                sample: 'The quick brown fox',
              ),
            ),
          ),
        ),
      );
    }

    /// The fill layer is the last sample drawn; the one before it is the
    /// outline stroke.
    TextStyle fillStyle(WidgetTester tester) {
      final texts = tester
          .widgetList<Text>(find.text('The quick brown fox'))
          .toList();
      return texts.last.style!;
    }

    testWidgets('sizes the sample exactly as libVLC will', (tester) async {
      const settings = PlayerSettings(subtitleSize: 22);
      await pumpPreview(tester, settings);

      // Rendered height is video height / relative size — the engine's own
      // rule, read back off the same mapping the engine is handed.
      final relative = subtitleStyleFrom(settings).relativeFontSize!;
      expect(fillStyle(tester).fontSize, 1080 / relative);
    });

    testWidgets('a bigger setting really is bigger', (tester) async {
      await pumpPreview(tester, const PlayerSettings(subtitleSize: 22));
      final small = fillStyle(tester).fontSize!;

      await pumpPreview(tester, const PlayerSettings(subtitleSize: 44));
      expect(fillStyle(tester).fontSize, greaterThan(small));
    });

    testWidgets('uses the chosen text colour', (tester) async {
      await pumpPreview(
        tester,
        const PlayerSettings(subtitleColor: 0xFFFFEB3B),
      );
      expect(fillStyle(tester).color, const Color(0xFFFFEB3B));
    });

    testWidgets('draws no box at zero opacity, and one above it', (
      tester,
    ) async {
      Color? boxColour() {
        // Closest Container above the two text layers: the box itself.
        final box = tester
            .widgetList<Container>(
              find.ancestor(
                of: find.byType(Stack),
                matching: find.byType(Container),
              ),
            )
            .first;
        return box.color;
      }

      await pumpPreview(
        tester,
        const PlayerSettings(subtitleBackgroundOpacity: 0),
      );
      expect(boxColour(), isNull);

      await pumpPreview(
        tester,
        const PlayerSettings(
          subtitleBackgroundColor: 0xFF000000,
          subtitleBackgroundOpacity: 0.5,
        ),
      );
      expect(boxColour(), isNotNull);
    });
  });

  group('SubtitleAppearanceGroup', () {
    Future<void> pumpGroup(WidgetTester tester, PlayerSettings settings) {
      return tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListView(
                children: [
                  const Focus(autofocus: true, child: SizedBox(height: 24)),
                  SubtitleAppearanceGroup(settings: settings),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows every editable field with its current value', (
      tester,
    ) async {
      await pumpGroup(
        tester,
        const PlayerSettings(
          subtitleSize: 30,
          subtitleColor: 0xFFFFEB3B,
          subtitleBackgroundColor: 0xFF000000,
          subtitleBackgroundOpacity: 0.5,
        ),
      );

      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('Text colour'), findsOneWidget);
      expect(find.text('Yellow'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Black · 50%'), findsOneWidget);
    });

    testWidgets('DOWN walks the rows, so the preview is not a dead end', (
      tester,
    ) async {
      await pumpGroup(tester, const PlayerSettings());
      await tester.pump();

      final visited = <String?>[];
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        visited.add(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<SettingsTile>()
              ?.title,
        );
      }

      expect(visited, <String>[
        'Text size',
        'Text colour',
        'Background',
        'Reset subtitle appearance',
      ]);
    });
  });
}
