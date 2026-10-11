import 'package:shared_preferences/shared_preferences.dart';

/// Directory scoping (PRD §3). The indexer (Phase 2) may ONLY crawl URIs in
/// this list. No full-disk crawl is possible: an empty scope means zero files
/// are visible to the crawler, and removal immediately revokes access.
class ScopeStore {
  static const keyScopedUris = 'scoped_uris';

  static Future<List<String>> getScopedUris() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(keyScopedUris) ?? <String>[];
  }

  /// Replace the whole scope (folder picker "Save" action).
  static Future<void> setScopedUris(List<String> uris) async {
    final prefs = await SharedPreferences.getInstance();
    final deduped = uris.toSet().toList()..sort();
    await prefs.setStringList(keyScopedUris, deduped);
  }

  static Future<void> addUri(String uri) async {
    final current = await getScopedUris();
    if (!current.contains(uri)) {
      current.add(uri);
      await setScopedUris(current);
    }
  }

  /// Revoke a folder. Phase 2 crawler must drop its indexed rows on revoke.
  static Future<void> removeUri(String uri) async {
    final current = await getScopedUris();
    current.remove(uri);
    await setScopedUris(current);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyScopedUris);
  }
}
