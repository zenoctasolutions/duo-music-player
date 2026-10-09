// lib/smart_mix_service.dart
//
// Builds a "Smart Mix" playlist from the local library, ranked by how close
// each song's DSP-analyzed mood is to a user-picked target mood, with a
// bias toward favorited/recently-played songs. Rule-based ranking over
// already-local data (AudioAnalysisService + FavoritesNotifier +
// RecentlyPlayedNotifier) — no network call, no new AI model.
//
// ffmpeg analysis is real per-song decode work, so a mix generation caps
// how many *new* decodes it triggers rather than analyzing an entire large
// library on every request.
import 'audio_analysis_service.dart';
import 'list_page.dart' show FavoritesNotifier, RecentlyPlayedNotifier;

class SmartMixResult {
  final List<String> paths;
  final int analyzedCount;
  const SmartMixResult(this.paths, this.analyzedCount);
}

class SmartMixService {
  SmartMixService._internal();
  static final SmartMixService instance = SmartMixService._internal();

  /// Upper bound on how many songs a single Smart Mix build will analyze —
  /// keeps generation time and ffmpeg/battery cost bounded regardless of
  /// library size.
  static const int _maxCandidates = 80;
  static const int _maxPlaylistLength = 30;

  static const List<MoodBucket> _moodOrder = [
    MoodBucket.chill,
    MoodBucket.mellow,
    MoodBucket.balanced,
    MoodBucket.upbeat,
    MoodBucket.energetic,
  ];

  double _moodDistance(MoodBucket a, MoodBucket b) =>
      (_moodOrder.indexOf(a) - _moodOrder.indexOf(b)).abs().toDouble();

  Future<SmartMixResult> generate({
    required List<String> libraryPaths,
    required MoodBucket targetMood,
    void Function(int done, int total)? onProgress,
  }) async {
    if (libraryPaths.isEmpty) return const SmartMixResult([], 0);

    await FavoritesNotifier.instance.init();
    await RecentlyPlayedNotifier.instance.init();
    final favorites = FavoritesNotifier.instance.favoritesSet;
    final recent = RecentlyPlayedNotifier.instance.paths.value.toSet();

    // Favorited/recently-played songs are analyzed first — most likely to
    // yield a good mix and most worth the ffmpeg cost — then the rest of
    // the library fills up to the candidate cap.
    final prioritized = <String>[
      ...libraryPaths.where((path) => favorites.contains(path) || recent.contains(path)),
      ...libraryPaths.where((path) => !favorites.contains(path) && !recent.contains(path)),
    ];
    final candidates = prioritized.take(_maxCandidates).toList();

    final analyses = await AudioAnalysisService.instance.analyzeAll(
      candidates,
      onProgress: onProgress,
    );

    final scored = <MapEntry<String, double>>[];
    analyses.forEach((path, analysis) {
      var score = _moodDistance(analysis.mood, targetMood);
      if (favorites.contains(path)) score -= 0.5;
      if (recent.contains(path)) score -= 0.15;
      scored.add(MapEntry(path, score));
    });
    scored.sort((a, b) => a.value.compareTo(b.value));

    final picked = scored.map((e) => e.key).take(_maxPlaylistLength).toList();
    picked.shuffle();
    return SmartMixResult(picked, analyses.length);
  }
}
