import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'vault_crypto.dart';
import 'vault_prefs.dart';

/// Encrypted backup of the whole (real) vault.
///
/// Every file under the vault root is already AES-encrypted with the vault
/// password, so the backup zips them as-is plus a small manifest, then
/// encrypts the zip once more with the vault password. The result is a
/// single `vault_backup_<timestamp>.zip.enc` file the user can keep
/// anywhere (Google Drive, laptop, ...).
///
/// Note: the salt lives in this device's Hive box, so a backup restores
/// cleanly on this device. On a fresh install (new salt) it will not
/// decrypt — the backup is device-bound by design.
class VaultBackup {
  static const int manifestVersion = 1;

  /// Creates `vault_backup_<timestamp>.zip.enc` inside [targetDir].
  /// Returns the created file path. Throws on failure.
  ///
  /// [vaultKey] is the derived vault key (see VaultCrypto.deriveKey).
  static Future<String> exportBackup({
    required String vaultRoot,
    required Uint8List vaultKey,
    required String targetDir,
  }) async {
    final settings = Hive.box('settings');
    final manifest = jsonEncode({
      'app': 'notes-vault',
      'version': manifestVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'albums': settings.get(VaultPrefs.albums,
          defaultValue: const <String>[]),
      'sort': settings.get(VaultPrefs.sortMode,
          defaultValue: 'newest'),
    });

    final archive = Archive();
    final manifestBytes = utf8.encode(manifest);
    archive.addFile(ArchiveFile(
      'manifest.json',
      manifestBytes.length,
      manifestBytes,
    ));

    final root = Directory(vaultRoot);
    if (await root.exists()) {
      await for (final e in root.list(recursive: true)) {
        if (e is File) {
          final rel = p.relative(e.path, from: root.path);
          final bytes = await e.readAsBytes();
          archive.addFile(
            ArchiveFile('vault/$rel', bytes.length, bytes),
          );
        }
      }
    }

    final zipBytes = ZipEncoder().encode(archive);
    final encrypted = VaultCrypto.encryptBytes(
      Uint8List.fromList(zipBytes),
      vaultKey,
    );

    final out = File(
      '$targetDir/vault_backup_${DateTime.now().millisecondsSinceEpoch}.zip.enc',
    );
    await out.writeAsBytes(encrypted, flush: true);
    return out.path;
  }

  /// Decrypts a backup payload, accepting backups made before Phase B
  /// (legacy single-SHA-256 key) as well as current ones.
  /// Returns the zip bytes and whether the backup used the legacy key.
  static ({Uint8List zipBytes, bool wasLegacy}) _decryptBackup(
    Uint8List data,
    String password,
    String salt,
  ) {
    try {
      return (
        zipBytes: VaultCrypto.decryptBytes(
            data, VaultCrypto.deriveKey(password, salt)),
        wasLegacy: false
      );
    } catch (_) {}
    return (
      zipBytes: VaultCrypto.decryptBytes(
          data, VaultCrypto.deriveKeyLegacy(password, salt)),
      wasLegacy: true
    );
  }

  /// Reads a backup file's manifest using [password]. Throws on a wrong
  /// password, a corrupt file, or a non-backup file.
  static Future<Map<String, dynamic>> inspectBackup({
    required String backupPath,
    required String password,
    required String salt,
  }) async {
    final data = await File(backupPath).readAsBytes();
    final zipBytes =
        _decryptBackup(data, password, salt).zipBytes;
    final archive = ZipDecoder().decodeBytes(zipBytes);
    for (final f in archive.files) {
      if (f.isFile && f.name == 'manifest.json') {
        final content = f.content as List<int>;
        final decoded = jsonDecode(utf8.decode(content));
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    }
    throw const FormatException('Not a vault backup (no manifest)');
  }

  /// Restores a backup OVER the current vault: stages the backup's files,
  /// then wipes [vaultRoot] and moves them in. Restores the album list and
  /// sort order, and updates the stored password hash to the backup's
  /// password.
  ///
  /// The caller must warn clearly and get explicit confirmation first:
  /// everything currently in the vault is replaced.
  static Future<void> restoreBackup({
    required String backupPath,
    required String password,
    required String salt,
    required String vaultRoot,
  }) async {
    final data = await File(backupPath).readAsBytes();
    final decrypted = _decryptBackup(data, password, salt);
    final zipBytes = decrypted.zipBytes;
    final archive = ZipDecoder().decodeBytes(zipBytes);

    Map<String, dynamic>? manifest;
    final entries = <ArchiveFile>[];
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (f.name == 'manifest.json') {
        final content = f.content as List<int>;
        final decoded = jsonDecode(utf8.decode(content));
        if (decoded is Map) {
          manifest = Map<String, dynamic>.from(decoded);
        }
      } else if (f.name.startsWith('vault/')) {
        entries.add(f);
      }
    }
    if (manifest == null) {
      throw const FormatException('Not a vault backup (no manifest)');
    }

    // Stage everything into a temp dir first; only swap when complete,
    // so a corrupt backup never leaves a half-written vault.
    //
    // If the backup was made before Phase B, its files are encrypted with
    // the legacy key: re-encrypt them to the current key while staged, so
    // the restored vault is fully on the new scheme.
    final staging =
        await Directory.systemTemp.createTemp('vault_restore_');
    try {
      for (final f in entries) {
        final rel = f.name.substring('vault/'.length);
        final out = File(p.join(staging.path, rel));
        // Safety: never write outside the staging dir (zip-slip).
        if (!p.isWithin(staging.path, out.path)) {
          throw const FormatException(
              'Backup contains an unsafe path');
        }
        final parent = out.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        await out.writeAsBytes(f.content as List<int>,
            flush: true);
      }

      if (decrypted.wasLegacy) {
        // Entries were staged directly under staging.path ('vault/'
        // was stripped when writing), so rekey the staging root itself.
        await VaultCrypto.rekey(
          vaultRoot: staging.path,
          oldKey: VaultCrypto.deriveKeyLegacy(password, salt),
          newKey: VaultCrypto.deriveKey(password, salt),
        );
      }

      final root = Directory(vaultRoot);
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      await staging.rename(vaultRoot);
    } catch (_) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }

    // Restore album list + sort order + password hash.
    final settings = Hive.box('settings');
    final albums = manifest['albums'];
    if (albums is List) {
      settings.put(VaultPrefs.albums,
          albums.map((e) => e.toString()).toList());
    }
    final sort = manifest['sort'];
    if (sort is String) {
      settings.put(VaultPrefs.sortMode, sort);
    }
    settings.put(
      VaultCrypto.passwordHashKey,
      VaultCrypto.hashPassword(password, salt),
    );
    // Trash/favorite metadata may reference files that no longer exist
    // after a restore; drop it to avoid ghosts.
    VaultPrefs.remove(VaultPrefs.trashMeta);
    VaultPrefs.remove(VaultPrefs.favorites);
    // Break-in counters reset: a restore is an owner action.
    VaultPrefs.setInt(VaultPrefs.failedAttempts, 0);
    VaultPrefs.setInt(VaultPrefs.lockoutUntilMs, 0);
  }
}
