// lib/app_update_service.dart
//
// Tells existing users about new versions without Firebase or a server:
//
// 1. "What's new" sheet: shown once after the app is updated to a new
//    version. Fresh installs never see it. Version 2.0.2 and later always
//    wrote SharedPreferences keys (library scan cache, theme, EQ...), so empty
//    preferences at startup mean a brand-new install.
// 2. Google Play in-app updates (flexible flow): when Play has a newer build,
//    Google's own "Update available" dialog appears. The download runs in the
//    background while music keeps playing, then a "Restart" bar finishes the
//    install. If the user says no, the same version isn't offered again for
//    3 days. Only works for Play installs; anything else (sideloaded or
//    emulator builds) fails the check quietly.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'duo_page.dart' show kDuoLeftColor, kDuoRightColor;

class AppUpdateService {
  AppUpdateService._();

  static final navigatorKey = GlobalKey<NavigatorState>();
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static const _kSeenVersion = 'whats_new_seen_version';
  static const _kDeclinedCode = 'update_declined_version_code';
  static const _kDeclinedAt = 'update_declined_at_ms';
  static const _declineCooldown = Duration(days: 3);

  static bool _existingInstall = false;
  static bool _started = false;
  static StreamSubscription<InstallStatus>? _installSub;

  /// Call in main() before anything writes SharedPreferences.
  static Future<void> captureInstallState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _existingInstall = prefs.getKeys().isNotEmpty;
    } catch (_) {}
  }

  /// Call once after the first frame. Shows "What's new" if needed, then
  /// checks Play for an update.
  static void start() {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    // Let the library load and the first screen settle before any dialog.
    Future.delayed(const Duration(seconds: 3), () async {
      await _maybeShowWhatsNew();
      await _checkPlayUpdate();
    });
  }

  // ---------------------------------------------------------------- What's new
  static Future<void> _maybeShowWhatsNew() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final version = (await PackageInfo.fromPlatform()).version;
      final seen = prefs.getString(_kSeenVersion);
      await prefs.setString(_kSeenVersion, version);
      if (seen == version) return;
      if (seen == null && !_existingInstall) return; // fresh install
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => _WhatsNewSheet(version: version),
      );
    } catch (e) {
      debugPrint('WhatsNew: $e');
    }
  }

  // ------------------------------------------------------- Play in-app update
  static Future<void> _checkPlayUpdate() async {
    try {
      final info = await InAppUpdate.checkForUpdate();

      // A download started earlier may already be finished or still running.
      if (info.installStatus == InstallStatus.downloaded) {
        _showRestartBar();
        return;
      }
      if (info.updateAvailability != UpdateAvailability.updateAvailable || !info.flexibleUpdateAllowed) {
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final code = info.availableVersionCode ?? -1;
      final declinedCode = prefs.getInt(_kDeclinedCode);
      final declinedAt = prefs.getInt(_kDeclinedAt) ?? 0;
      final sinceDecline = DateTime.now().millisecondsSinceEpoch - declinedAt;
      if (declinedCode == code && sinceDecline < _declineCooldown.inMilliseconds) return;

      _installSub ??= InAppUpdate.installUpdateListener.listen((status) {
        if (status == InstallStatus.downloaded) _showRestartBar();
      });

      final result = await InAppUpdate.startFlexibleUpdate();
      if (result == AppUpdateResult.userDeniedUpdate) {
        await prefs.setInt(_kDeclinedCode, code);
        await prefs.setInt(_kDeclinedAt, DateTime.now().millisecondsSinceEpoch);
      }
    } catch (e) {
      // Not installed from Play, no Play Store, offline, etc.
      debugPrint('InAppUpdate: $e');
    }
  }

  static void _showRestartBar() {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('A new version of Duo Music Player is ready.'),
        duration: const Duration(days: 1),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'RESTART',
          onPressed: () async {
            try {
              await InAppUpdate.completeFlexibleUpdate();
            } catch (e) {
              debugPrint('InAppUpdate complete: $e');
            }
          },
        ),
      ),
    );
  }
}

class _WhatsNewSheet extends StatelessWidget {
  final String version;
  const _WhatsNewSheet({required this.version});

  static const _items = <(IconData, Color, String, String)>[
    (Icons.headphones_rounded, kDuoRightColor, 'Duo Mode',
        'Two songs at once, one in each earbud. Share your earphones and each of you hears your own song. Open the Duo tab.'),
    (Icons.lyrics_rounded, kDuoLeftColor, 'Synced lyrics',
        'Lyrics scroll with the song. Tap a line to jump to it. Swipe the album art on Now Playing.'),
    (Icons.equalizer_rounded, kDuoRightColor, '10-band equalizer & sound effects',
        'Bass boost, virtualizer, crossfade, volume leveling and a separate EQ for each device.'),
    (Icons.edit_note_rounded, kDuoLeftColor, 'Tag editor & album art',
        'Fix titles, artists and covers, and download missing album art.'),
    (Icons.palette_rounded, kDuoRightColor, 'Make it yours',
        'Pure black theme, 8 accent colors, Material You and new home-screen widgets.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("What's new", style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Duo Music Player $version', style: TextStyle(color: sub)),
            const SizedBox(height: 20),
            for (final (icon, color, title, body) in _items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, color: color, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(body, style: TextStyle(color: sub, fontSize: 13.5, height: 1.35)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [kDuoLeftColor, kDuoRightColor]),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
