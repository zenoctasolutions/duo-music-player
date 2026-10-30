// lib/lastfm_page.dart
//
// Settings → Last.fm: sign in/out, pause scrobbling, see queued scrobbles.

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'lastfm_service.dart';
import 'ad_widgets.dart';
import 'settings_page.dart' show SettingsColors;
import 'motion/motion_kit.dart';

class LastFmPage extends StatefulWidget {
  final bool isDark;
  const LastFmPage({super.key, required this.isDark});

  @override
  State<LastFmPage> createState() => _LastFmPageState();
}

class _LastFmPageState extends State<LastFmPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;
  SettingsColors get c => SettingsColors(widget.isDark);

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await LastFmService.instance.signIn(_user.text, _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) _pass.clear();
  }

  @override
  Widget build(BuildContext context) {
    final fm = LastFmService.instance;
    final accent = AppPalette.accent;
    return ValueListenableBuilder<int>(
      valueListenable: fm.changes,
      builder: (context, _, __) => Scaffold(
        bottomNavigationBar: const BannerAdWidget(),
        backgroundColor: c.backgroundColor,
        appBar: AppBar(title: const Text('Last.fm'), backgroundColor: c.appBarBackground, foregroundColor: c.appBarForeground, elevation: 0),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          FadeSlideIn(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(colors: [Color(0xFFD51007), Color(0xFFFF5A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.graphic_eq_rounded, color: Colors.white),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text('Scrobble what you play to your Last.fm profile: track your listening history and get recommendations.',
                      style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.35, fontWeight: FontWeight.w500)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          if (!fm.isConfigured)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(22)),
              child: Text(
                'Last.fm scrobbling isn\'t configured in this build yet (the app needs its Last.fm API key). '
                'It will be available in a future update.',
                style: TextStyle(color: c.primaryText, fontSize: 13),
              ),
            )
          else if (fm.isSignedIn) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: c.cardColor, borderRadius: BorderRadius.circular(22), border: Border.all(color: c.divider)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.check_circle_rounded, color: accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Signed in as ${fm.username}', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: fm.enabled,
                  activeColor: accent,
                  title: Text('Scrobble my listening', style: TextStyle(color: c.primaryText)),
                  subtitle: Text(
                    fm.pendingCount == 0 ? 'All scrobbles sent' : '${fm.pendingCount} waiting to be sent',
                    style: TextStyle(color: c.secondaryText, fontSize: 12),
                  ),
                  onChanged: fm.setEnabled,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: fm.signOut, child: Text('Sign out', style: TextStyle(color: c.secondaryText))),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Text('A song is scrobbled after you\'ve listened to half of it (or 4 minutes). Songs need artist and title tags.',
                style: TextStyle(color: c.tertiaryText, fontSize: 12)),
          ] else ...[
            TextField(
              controller: _user,
              style: TextStyle(color: c.primaryText),
              decoration: InputDecoration(labelText: 'Last.fm username', border: OutlineInputBorder(borderRadius: BorderRadius.circular(22))),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              obscureText: true,
              style: TextStyle(color: c.primaryText),
              decoration: InputDecoration(labelText: 'Password', border: OutlineInputBorder(borderRadius: BorderRadius.circular(22))),
              onSubmitted: (_) => _signIn(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26))),
              onPressed: _busy ? null : _signIn,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
            const SizedBox(height: 10),
            Text('Your password is sent securely to Last.fm only to create a session; it isn\'t stored on the device.',
                style: TextStyle(color: c.tertiaryText, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}
