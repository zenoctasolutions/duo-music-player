// lib/l10n/l10n.dart
//
// Convenience access to the generated localizations:
//   context.l10n.navLibrary
// Regenerate with `flutter gen-l10n` after editing lib/l10n/app_en.arb.
import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

export 'gen/app_localizations.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
