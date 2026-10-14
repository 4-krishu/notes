import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'vault_prefs.dart';

/// Resolves every on-disk path and Hive key for one vault.
///
/// There are two vaults on disk: the real one (`vault/`) and the decoy
/// (`vault_decoy/`). Everything — albums, trash, intruder log, notes —
/// lives under the active root, so decoy mode is just a different
/// [VaultStorage].
class VaultStorage {
  final bool decoy;

  const VaultStorage({this.decoy = false});

  /// Directory name under the app documents folder.
  String get rootName => decoy ? 'vault_decoy' : 'vault';

  /// Prefix used in favorite ids: 'v' for the real vault, 'd' for decoy.
  String get idPrefix => decoy ? 'd' : 'v';

  String get albumsKey =>
      decoy ? VaultPrefs.decoyAlbums : VaultPrefs.albums;
  String get sortKey =>
      decoy ? VaultPrefs.decoySortMode : VaultPrefs.sortMode;

  Future<String> rootPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$rootName';
  }

  Future<Directory> _ensure(String path) async {
    final d = Directory(path);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  Future<Directory> albumDir(String name) async {
    final root = await rootPath();
    return _ensure('$root/$name');
  }

  /// Hidden trash folder: deleted files rest here (still encrypted).
  Future<Directory> trashDir() async {
    final root = await rootPath();
    return _ensure('$root/.trash');
  }

  /// Hidden intruder-selfie folder (real vault only).
  Future<Directory> intruderDir() async {
    final root = await rootPath();
    return _ensure('$root/.intruder');
  }

  /// Hidden folder for encrypted vault text notes.
  Future<Directory> notesDir() async {
    final root = await rootPath();
    return _ensure('$root/.notes');
  }

  /// Favorite id for an encrypted file name, e.g. "v:1730000000000_0.jpg.enc".
  String favId(String encFileName) => '$idPrefix:$encFileName';
}
