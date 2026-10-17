import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Encrypted Hive box for everything the vault keeps in settings: the salt,
/// the password / decoy / security-answer hashes, album lists, trash
/// metadata, favorites, lockout counters and feature flags.
///
/// The box is AES-256 encrypted ([HiveAesCipher]). The 256-bit key is
/// generated once, kept in the OS keystore via [FlutterSecureStorage], and
/// never touches disk unprotected.
///
/// Migration: installs created before this change keep a PLAINTEXT box that
/// is also named 'settings'. On first launch the entries are copied into the
/// encrypted box, verified, and only then is the old box deleted. A JSON
/// backup is staged before anything is deleted, so a crash mid-migration
/// can be recovered on the next launch instead of losing data.
///
/// The box keeps its name ('settings'), so every existing
/// `Hive.box('settings')` call site works unchanged.
class VaultBoxes {
  static const String settingsName = 'settings';

  static const String _keyStorageKey = 'vault_hive_key_v1';
  static const String _migratedFlag = 'vault_hive_enc_v1';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// Loads the 256-bit box key from the OS keystore, generating and
  /// storing it on first run.
  static Future<Uint8List> _loadOrCreateKey() async {
    final stored = await _secure.read(key: _keyStorageKey);
    if (stored != null && stored.isNotEmpty) {
      return base64Url.decode(stored);
    }
    final rand = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => rand.nextInt(256)),
    );
    await _secure.write(
      key: _keyStorageKey,
      value: base64Url.encode(key),
    );
    return key;
  }

  static Future<File> _migrationBackupFile() async {
    final tmp = await getTemporaryDirectory();
    return File('${tmp.path}/vault_settings_migration.json');
  }

  /// Opens the encrypted settings box, migrating from the old plaintext
  /// box on first run. Call after `Hive.initFlutter()` and before any
  /// `Hive.box('settings')` access (i.e. once, in `main()`).
  static Future<Box> openSettings() async {
    final cipher = HiveAesCipher(await _loadOrCreateKey());

    final migrated = await _secure.read(key: _migratedFlag) == '1';
    if (!migrated) {
      await _migrate(cipher);
      await _secure.write(key: _migratedFlag, value: '1');
    }
    return Hive.openBox(settingsName, encryptionCipher: cipher);
  }

  static Future<void> _migrate(HiveAesCipher cipher) async {
    // Case 1: an old box exists. If it reads as plaintext, move its
    // entries into a fresh encrypted box. (If it doesn't read as
    // plaintext it is left alone: opening it with the cipher below will
    // either succeed or fail loudly, but we never destroy what we can't
    // read.)
    Map<String, dynamic>? plaintextData;
    if (await Hive.boxExists(settingsName)) {
      try {
        final old = await Hive.openBox(settingsName); // no cipher
        try {
          plaintextData =
              Map<String, dynamic>.from(old.toMap());
        } finally {
          await old.close();
        }
      } catch (_) {
        plaintextData = null;
      }
    }

    if (plaintextData != null) {
      // Stage a JSON backup BEFORE deleting anything, so a crash between
      // the delete and the re-create can't lose the user's settings.
      // (All values we store — strings, ints, bools, string lists, trash
      // metadata maps — are JSON-encodable.)
      final backup = await _migrationBackupFile();
      await backup.writeAsString(
        jsonEncode(plaintextData),
        flush: true,
      );

      await Hive.deleteBoxFromDisk(settingsName);

      final fresh = await Hive.openBox(
        settingsName,
        encryptionCipher: cipher,
      );
      if (plaintextData.isNotEmpty) {
        await fresh.putAll(plaintextData);
      }
      // Verify the round-trip before declaring success.
      if (fresh.toMap().length != plaintextData.length) {
        throw StateError('Settings migration verification failed');
      }
      try {
        await backup.delete();
      } catch (_) {}
      return;
    }

    // Case 2: no readable plaintext box. Either a fresh install (nothing
    // to do) or a crash deleted the old box before the new one was
    // written — recover from the staged backup if one exists.
    try {
      final backup = await _migrationBackupFile();
      if (await backup.exists()) {
        final data = Map<String, dynamic>.from(
          jsonDecode(await backup.readAsString()) as Map,
        );
        final fresh = await Hive.openBox(
          settingsName,
          encryptionCipher: cipher,
        );
        if (data.isNotEmpty) {
          await fresh.putAll(data);
        }
        await backup.delete();
      }
    } catch (_) {}
  }
}
