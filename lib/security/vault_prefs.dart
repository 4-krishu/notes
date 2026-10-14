import 'package:hive/hive.dart';

/// Central registry of every Hive 'settings' key the vault uses.
///
/// Keeps key names (and their value shapes) in one place so the lock
/// screen, home screen, settings and trash helpers can't drift apart.
class VaultPrefs {
  static Box get _box => Hive.box('settings');

  // --- security ---
  static const String biometricEnabled = 'vault_biometric_enabled';
  static const String autoLockSeconds = 'vault_autolock_seconds'; // 0 = off
  static const String shakeLockEnabled = 'vault_shake_lock';
  static const String failedAttempts = 'vault_failed_attempts';
  static const String lockoutUntilMs = 'vault_lockout_until';
  static const String decoyHash = 'vault_decoy_hash';
  static const String decoyAlbums = 'vault_decoy_albums';

  // --- organization ---
  static const String albums = 'vault_albums';
  static const String sortMode = 'vault_sort';
  static const String decoySortMode = 'vault_decoy_sort';

  /// Favorite file ids: "<v|d>:<encrypted file name>", e.g. "v:1730000_0.jpg.enc".
  static const String favorites = 'vault_favorites';

  /// Trash metadata: { trashFileName: {album, deletedAt, kind} }.
  static const String trashMeta = 'vault_trash_meta';

  static bool getBool(String key, [bool def = false]) =>
      (_box.get(key, defaultValue: def) as bool?) ?? def;
  static void setBool(String key, bool v) => _box.put(key, v);

  static int getInt(String key, [int def = 0]) =>
      (_box.get(key, defaultValue: def) as int?) ?? def;
  static void setInt(String key, int v) => _box.put(key, v);

  static String? getString(String key) => _box.get(key) as String?;
  static void setString(String key, String v) => _box.put(key, v);
  static void remove(String key) => _box.delete(key);

  static List<String> getStringList(String key) {
    final v = _box.get(key, defaultValue: const <String>[]);
    if (v is List) return v.map((e) => e.toString()).toList();
    return const <String>[];
  }

  static void setStringList(String key, List<String> v) =>
      _box.put(key, v);

  static Map<String, Map<String, dynamic>> getTrashMeta() {
    final v = _box.get(trashMeta, defaultValue: const {});
    final out = <String, Map<String, dynamic>>{};
    if (v is Map) {
      v.forEach((k, val) {
        if (val is Map) {
          out[k.toString()] = Map<String, dynamic>.from(val);
        }
      });
    }
    return out;
  }

  static void setTrashMeta(Map<String, Map<String, dynamic>> meta) =>
      _box.put(trashMeta, meta);
}
