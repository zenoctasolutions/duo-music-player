// Localization smoke test: the app's localization delegates resolve and the
// bottom-nav labels come from the ARB template. (Replaces the stale
// counter-app test from the initial commit.)
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music/l10n/l10n.dart';

void main() {
  testWidgets('MaterialApp with app localizations shows the Library nav label', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            Text(context.l10n.navLibrary),
            Text(context.l10n.songCount(1)),
            Text(context.l10n.songCount(3)),
          ]),
        ),
      ),
    ));
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('1 song'), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);
  });
}
