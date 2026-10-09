// lib/online_lyrics.dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_palette.dart';

class OnlineLyricsPopup extends StatelessWidget {
  final String songTitle;
  final String artistName;
  final bool isDarkMode;

  const OnlineLyricsPopup({
    Key? key,
    required this.songTitle,
    required this.artistName,
    required this.isDarkMode,
  }) : super(key: key);

  Future<void> _searchLyrics(BuildContext context) async {
    // Build a friendly search query
    final trimmedTitle = songTitle.trim();
    final trimmedArtist = artistName.trim();
    final query = trimmedArtist.isEmpty
        ? 'lyrics $trimmedTitle'
        : 'lyrics $trimmedTitle $trimmedArtist';

    final uri = Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(query)}');

    // Choose a launch mode that works for web and mobile
    final preferredMode = kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication;

    try {
      // Try to launch the URL. launchUrl returns a Future<bool>.
      final launched = await launchUrl(uri, mode: preferredMode);

      // If it returns false, try a fallback launch (platform default).
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      // If platform channel isn't available or other error occurs, show a snackbar
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open browser to search lyrics.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = isDarkMode ? AppPalette.darkCard : Colors.white;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subtitleColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Lyrics Search",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor),
            ),
            const SizedBox(height: 16),
            Text(
              songTitle,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppPalette.accent),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              artistName,
              style: TextStyle(fontSize: 14, color: subtitleColor),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                // Close dialog first for smooth UX, then try to open browser.
                Navigator.pop(context);
                _searchLyrics(context);
              },
              icon: const Icon(Icons.public, color: Colors.white),
              label: const Text("Search Online", style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppPalette.accent,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel", style: TextStyle(color: subtitleColor)),
            ),
          ],
        ),
      ),
    );
  }
}
