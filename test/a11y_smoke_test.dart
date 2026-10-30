// Accessibility smoke tests: large text (2.0x) must not overflow, key nodes
// must carry labels, and the Duo Logo palette must keep readable contrast.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:music/app_palette.dart';
import 'package:music/l10n/l10n.dart';
import 'package:music/library/folders/folder_tree.dart';
import 'package:music/library/library_motion.dart';
import 'package:music/library/overview/overview_home.dart';
import 'package:music/library/widgets/library_widgets.dart';
import 'package:music/player/seek_bar.dart';
import 'package:music/ui/animated_nav_bar.dart';
import 'package:music/ui/app_page_bar.dart';

Widget host(Widget child, {double scale = 1.0, bool appBar = false, PreferredSizeWidget? bar}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (ctx, c) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
      child: c!,
    ),
    home: Scaffold(appBar: bar, body: child),
  );
}

void main() {
  const scales = [1.0, 1.5, 2.0];

  group('AnimatedNavBar', () {
    Widget bar(int index) => Builder(
          builder: (context) => Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedNavBar(
              destinations: [
                NavDestination(Icons.library_music, context.l10n.navLibrary),
                NavDestination(Icons.radio, context.l10n.navRadio),
                NavDestination(Icons.headphones_rounded, context.l10n.navDuo),
                NavDestination(Icons.graphic_eq, context.l10n.navConverter),
                NavDestination(Icons.settings, context.l10n.navSettings),
              ],
              centerIndex: 2,
              currentIndex: index,
              selectedColor: Colors.purple,
              unselectedColor: Colors.grey,
              tabHint: (i, n) => context.l10n.navTabSemantics(i + 1, n),
              onTap: (_) {},
            ),
          ),
        );

    for (final s in scales) {
      testWidgets('no overflow at text scale $s', (tester) async {
        await tester.pumpWidget(host(bar(0), scale: s));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('announces selected state and "tab N of 5"', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(bar(1)));
      await tester.pump(const Duration(milliseconds: 600));
      final radio = tester.getSemantics(find.bySemanticsLabel(RegExp('^Radio')));
      expect(radio.getSemanticsData().hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(radio.getSemanticsData().hasFlag(SemanticsFlag.isButton), isTrue);
      expect(radio.hint, 'Tab 2 of 5');
      final lib = tester.getSemantics(find.bySemanticsLabel(RegExp('^Library')));
      expect(lib.getSemanticsData().hasFlag(SemanticsFlag.isSelected), isFalse);
      expect(lib.hint, 'Tab 1 of 5');
      handle.dispose();
    });
  });

  group('AppPageBar', () {
    testWidgets('title + labelled action survive 2.0x', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(const SizedBox(),
          scale: 2.0,
          bar: AppPageBar(
            title: 'Library',
            actions: [IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: () {})],
          )));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Search'), findsOneWidget);
      handle.dispose();
    });
  });

  group('NowPlayingSeekBar', () {
    testWidgets('is a slider with "m:ss of m:ss" value and +-10s actions', (tester) async {
      final handle = tester.ensureSemantics();
      final pos = ValueNotifier<Duration>(const Duration(seconds: 65));
      Duration? sought;
      await tester.pumpWidget(host(
        NowPlayingSeekBar(
          position: pos,
          duration: const Duration(minutes: 3),
          accent: Colors.purple,
          inactive: Colors.grey,
          labelColor: Colors.white,
          onSeek: (d) => sought = d,
        ),
        scale: 2.0,
      ));
      expect(tester.takeException(), isNull);
      final node = tester.getSemantics(find.bySemanticsLabel('Seek'));
      expect(node.getSemanticsData().hasFlag(SemanticsFlag.isSlider), isTrue);
      expect(node.value, '01:05 of 03:00');
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
      tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.increase);
      expect(sought, const Duration(seconds: 75));
      tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.decrease);
      expect(sought, const Duration(seconds: 55));
      handle.dispose();
    });
  });

  group('Library widgets', () {
    for (final s in scales) {
      testWidgets('PlayShuffleRow / empty state / toggle at $s', (tester) async {
        await tester.pumpWidget(host(
          Builder(builder: (context) {
            final colors = LibColors.of(context);
            return SingleChildScrollView(
              child: Column(children: [
                PlayShuffleRow(onPlay: () {}, onShuffle: () {}, colors: colors),
                SizedBox(
                  height: 400,
                  child: LibEmptyState(
                      icon: Icons.album, title: 'No albums found', message: 'Scan your library.', colors: colors),
                ),
                ViewToggleButton(grid: true, onPressed: () {}, color: colors.text),
              ]),
            );
          }),
          scale: s,
        ));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('EqualizerBars announces nothing', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const Center(child: EqualizerBars(color: Colors.red, playing: false))));
    expect(
      find.descendant(of: find.byType(EqualizerBars), matching: find.byType(ExcludeSemantics)),
      findsWidgets,
    );
    handle.dispose();
  });

  group('OverviewHome', () {
    OverviewHome home({String? Function(String)? artist, String? Function(String)? album}) => OverviewHome(
          files: [File('/music/Song One.mp3')],
          loading: false,
          recentlyPlayed: const [],
          nowPlayingPath: '/music/Song One.mp3',
          isPlaying: true,
          progress: 0.3,
          loadCover: (_) async => null,
          resolveArtist: artist,
          resolveAlbum: album,
          favoritesCount: 3,
          artistsCount: 2,
          hasPlaylists: false,
          bottomPadding: 0,
          onPlay: (_, __, ___) {},
          onTogglePlay: () {},
          onShuffleAll: () {},
          onOpenRecent: () {},
          onOpenAdded: () {},
          onOpenMost: () {},
          onOpenFolders: () {},
          onOpenFolder: (_, __) {},
          onOpenArtists: () {},
          onOpenAlbums: () {},
          onOpenGenres: () {},
          onOpenSmartMix: () {},
          onOpenPlaylists: () {},
          onOpenFavorites: () {},
        );

    testWidgets('hero prefers the player-known artist', (tester) async {
      await tester.pumpWidget(host(home(artist: (_) => 'Karthik, Shobana')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Karthik, Shobana'), findsOneWidget);
      expect(find.text('Unknown Artist'), findsNothing);
    });

    testWidgets('hero never shows "Unknown Artist" while unknown', (tester) async {
      await tester.pumpWidget(host(home()));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Unknown Artist'), findsNothing);
      expect(find.text('Song One'), findsWidgets);
    });

    testWidgets('hero falls back to the album', (tester) async {
      await tester.pumpWidget(host(home(album: (_) => 'Some Album')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Some Album'), findsOneWidget);
    });

    for (final s in scales) {
      testWidgets('no overflow at text scale $s', (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(host(home(artist: (_) => 'Karthik, Shobana'), scale: s));
        await tester.pump(const Duration(milliseconds: 800));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('FolderNode labels', () {
    test('collapsed chain shortens to the last two segments', () {
      final t = FolderTree.build(['/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/a.mp3']);
      final n = t.nodeFor('/storage/emulated/0/Android')!;
      expect(n.collapsedLabel(), 'Android/media/com.whatsapp/WhatsApp');
      expect(n.collapsedShortLabel(), '…/com.whatsapp/WhatsApp');
    });
  });

  group('Contrast (Duo Logo palette)', () {
    const card = Color(0xFF1C1C30);
    const violet = Color(0xFF9A6AE8);

    test('contrastRatio sanity', () {
      expect(AppPalette.contrastRatio(Colors.white, Colors.black), closeTo(21, 0.01));
    });

    test('raw violet text is borderline on the dark card (documented)', () {
      // 4.45:1 -- just under 4.5, hence AppPalette.accentText for text.
      expect(AppPalette.contrastRatio(violet, card), greaterThan(4.3));
    });

    test('unselected nav label (white70 @ 0.8) clears 4.5:1 on every gradient stop', () {
      for (final bg in const [Color(0xFF46163A), Color(0xFF14142C), Color(0xFF122C60)]) {
        final fg = Color.alphaBlend(Colors.white70.withValues(alpha: 0.7 * 0.8), bg);
        expect(AppPalette.contrastRatio(fg, bg), greaterThanOrEqualTo(4.5), reason: '$bg');
      }
    });

    test('accentText(dark) clears 4.5:1 on cards, page and gradient stops', () async {
      SharedPreferences.setMockInitialValues({'appearance_gradient_index': AppPalette.logoGradientIndex});
      await AppPalette.load();
      expect(AppPalette.isLogoTheme, isTrue);
      final t = AppPalette.accentText(dark: true);
      for (final bg in [AppPalette.darkCard, AppPalette.darkBackground, ...AppPalette.backgroundGradient!]) {
        expect(AppPalette.contrastRatio(t, bg), greaterThanOrEqualTo(4.5), reason: '$bg');
      }
      // The raw violet fails on the gradient's blue end; the text accent must not.
      expect(AppPalette.contrastRatio(violet, const Color(0xFF122C60)), lessThan(4.5));
    });
  });
}
