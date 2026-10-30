// lib/search/search_history.dart
//
// Last 12 distinct search queries, newest first, kept in shared_preferences.
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistory {
  SearchHistory._();

  static const String _key = 'global_search_history_v1';
  static const int maxEntries = 12;

  /// Pure helper: [list] with [query] moved to the front (case-insensitive
  /// de-duplication), capped at [maxEntries].
  static List<String> pushed(List<String> list, String query) {
    final q = query.trim();
    if (q.isEmpty) return List<String>.from(list);
    final out = <String>[q];
    for (final e in list) {
      if (e.toLowerCase() != q.toLowerCase()) out.add(e);
    }
    return out.length > maxEntries ? out.sublist(0, maxEntries) : out;
  }

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  static Future<List<String>> add(String query) async {
    final next = pushed(await load(), query);
    await _save(next);
    return next;
  }

  static Future<List<String>> remove(String query) async {
    final next = (await load()).where((e) => e != query).toList();
    await _save(next);
    return next;
  }

  static Future<void> clear() => _save(const []);

  static Future<void> _save(List<String> v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, v);
    } catch (_) {}
  }
}
