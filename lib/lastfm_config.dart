// lib/lastfm_config.dart
//
// Last.fm API credentials. Create them (free) at
//   https://www.last.fm/api/account/create
// signed in as the Zenocta account, then paste the "API key" and "Shared
// secret" below. While these are empty, Settings → Last.fm explains that
// scrobbling isn't configured in this build and nothing is sent.
//
// They can also be injected at build time without editing this file:
//   flutter build apk --dart-define=LASTFM_API_KEY=... --dart-define=LASTFM_SECRET=...
class LastFmConfig {
  static const String apiKey = String.fromEnvironment('LASTFM_API_KEY', defaultValue: '');
  static const String sharedSecret = String.fromEnvironment('LASTFM_SECRET', defaultValue: '');

  static bool get isConfigured => apiKey.isNotEmpty && sharedSecret.isNotEmpty;
}
