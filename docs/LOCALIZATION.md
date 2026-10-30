# Localization

The app uses Flutter's official `gen-l10n` tooling. Only the **English
template** exists today; no other languages are shipped yet.

| Piece | Location |
| --- | --- |
| Config | `l10n.yaml` |
| Template (source of truth) | `lib/l10n/app_en.arb` |
| Generated code (checked in) | `lib/l10n/gen/` |
| Access helper | `lib/l10n/l10n.dart` -> `context.l10n.someKey` |
| Wiring | `MaterialApp` in `lib/main.dart` (`localizationsDelegates`, `supportedLocales`) |

Packages: `flutter_localizations` (sdk) and `intl: ^0.20.2` (resolves to
0.20.3 in `pubspec.lock`); `flutter: generate: true` is set in `pubspec.yaml`.

## Add a language

1. Copy `lib/l10n/app_en.arb` to `lib/l10n/app_xx.arb` (`xx` = language code,
   e.g. `app_hi.arb`, `app_ta.arb`, `app_es.arb`).
2. Change `"@@locale"` to the new code and translate the values. Do not copy
   the `@key` metadata blocks (descriptions/placeholders) -- they live only in
   the template. Keep every `{placeholder}` and ICU plural structure intact.
   Missing keys fall back to English.
3. Run `flutter gen-l10n`. `AppLocalizations.supportedLocales` now includes
   the language and `MaterialApp` picks it up automatically.
4. Run `flutter analyze` and `flutter test`, then check text expansion
   (German/Tamil run long) at large font sizes.

## Conventions

- Keys are `lowerCamelCase`, prefixed by area: `nav*`, `tip*` (tooltips),
  `hero*`, `search*`, `settings*`, `ab*` (A-B loop) ...
- Anything with a number uses an ICU plural, never string concatenation:
  `"{count, plural, =1{1 song} other{{count} songs}}"`.
- Every placeholder is declared under its `@key` with a type; add a
  `description` when the English alone is ambiguous (e.g. "Back").
- Use `context.l10n.key` inside widgets. Strings needed outside a widget
  (snackbars from services, background code) should take an
  `AppLocalizations` argument -- see `QueueResult.localizedMessage`.
  `QueueResult.message` stays English for logs/tests.
- Do not edit `lib/l10n/gen/*`; re-run `flutter gen-l10n` after changing ARBs.
- Accessibility labels (tooltips, `Semantics`) are user-facing strings too and
  belong in the ARB.

## What is extracted so far

Bottom-nav labels and "tab N of 5" hint, Library tabs and app-bar tooltips,
Overview (hero, chips, shelf titles, Browse tiles, empty state), the player's
bottom actions, transport/header tooltips and A-B/queue snackbars, the seek
bar's screen-reader value, favorites button, song-row semantics, Search page,
and the Settings page's top-level card titles/subtitles.

Not extracted (still hard-coded English): most other screens (Albums, Artists,
Genres, Playlists, Radio, Duo, Converter, Equalizer, Sound effects, Last.fm,
Appearance, Library filters, tag editor, dialogs/sheets), sub-pages of
Settings, many snackbars, the notification/Android side (`strings.xml`,
shortcuts, QS tile), and the Dart-side `AppPalette.tabNames`.

## Finding remaining hard-coded strings

```sh
# Text widgets with a literal
grep -rEn "Text\(\s*(const )?['\"]" lib --include=*.dart --exclude-dir=gen
# titles, hints, tooltips, labels, snackbar content
grep -rEn "(title|label|hintText|tooltip|subtitle|content|semanticLabel): (const )?['\"]" lib --include=*.dart --exclude-dir=gen
# Text(const ...) with a nested literal and interpolated strings
grep -rEn "Text\(.*\\$\{?[a-zA-Z_]" lib --include=*.dart --exclude-dir=gen
```

When converting a screen, replace the literal with `context.l10n.key`, add the
key (and `@key` metadata) to `app_en.arb`, run `flutter gen-l10n`, and drop any
`const` that now wraps a localized widget.
