import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:hive/hive.dart';

/// Security helpers for the vault.
///
/// Design:
/// - A random salt is generated once and stored in the Hive 'settings' box.
/// - The vault password is NEVER stored. Only SHA-256(salt + password) is kept.
/// - Vault files are AES-256 encrypted. The key is SHA-256(salt + password),
///   a fresh random IV is used per file, and the IV is prepended to the
///   ciphertext on disk: [ iv (16 bytes) | ciphertext ].
class VaultCrypto {
  static const String passwordHashKey = 'vault_password_hash';
  static const String answerHashKey = 'vault_answer_hash';
  static const String _saltKey = 'vault_salt';

  /// Returns the existing salt, or creates and stores a new random one.
  static String getOrCreateSalt(Box settings) {
    final existing = settings.get(_saltKey) as String?;
    if (existing != null) return existing;

    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    final salt = base64Url.encode(bytes);
    settings.put(_saltKey, salt);
    return salt;
  }

  /// Hex SHA-256 hash of (salt + password). Stored instead of the password.
  static String hashPassword(String password, String salt) {
    return sha256.convert(utf8.encode('$salt::$password')).toString();
  }

  /// Hash of the (lowercased, trimmed) security answer. Stored instead of
  /// the plaintext answer.
  static String hashAnswer(String answer, String salt) {
    return sha256
        .convert(utf8.encode('$salt::${answer.trim().toLowerCase()}'))
        .toString();
  }

  static Uint8List _aesKey(String password, String salt) {
    // 32 bytes -> AES-256.
    return Uint8List.fromList(
      sha256.convert(utf8.encode('$salt::$password')).bytes,
    );
  }

  /// Encrypts [plainBytes]. Returns [ iv (16 bytes) | ciphertext ].
  static Uint8List encryptBytes(
    Uint8List plainBytes,
    String password,
    String salt,
  ) {
    final key = enc.Key(_aesKey(password, salt));
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key));
    final encrypted = encrypter.encryptBytes(plainBytes, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Decrypts data produced by [encryptBytes].
  /// Throws [FormatException] if the data is not a vault file, and an
  /// [ArgumentError]/[StateError] from the encrypt package if the password
  /// (key) is wrong.
  static Uint8List decryptBytes(
    Uint8List data,
    String password,
    String salt,
  ) {
    if (data.length < 17) {
      throw const FormatException('Not a vault file');
    }
    final iv = enc.IV(Uint8List.fromList(data.sublist(0, 16)));
    final cipher = enc.Encrypted(Uint8List.fromList(data.sublist(16)));
    final key = enc.Key(_aesKey(password, salt));
    final encrypter = enc.Encrypter(enc.AES(key));
    return Uint8List.fromList(encrypter.decryptBytes(cipher, iv: iv));
  }

  /// Compares two byte lists. Used to verify encrypt/decrypt round-trips.
  static bool bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Re-encrypts every `.enc` file under [vaultRoot] from [oldPassword] to
  /// [newPassword].
  ///
  /// Two-phase, so a wrong password or corrupt file aborts BEFORE anything
  /// is overwritten: first ALL files are decrypted with the old password
  /// (throws on failure), then each file is re-encrypted with the new
  /// password, verified, and only then written back.
  ///
  /// The caller must update the stored password hash only after this
  /// completes without throwing.
  static Future<void> changePassword({
    required String vaultRoot,
    required String oldPassword,
    required String newPassword,
    required String salt,
  }) async {
    final root = Directory(vaultRoot);
    final files = <File>[];
    if (await root.exists()) {
      await for (final e in root.list(recursive: true)) {
        if (e is File && e.path.endsWith('.enc')) files.add(e);
      }
    }

    // Phase 1: decrypt everything with the OLD password.
    final decrypted = <File, Uint8List>{};
    for (final f in files) {
      decrypted[f] = decryptBytes(await f.readAsBytes(), oldPassword, salt);
    }

    // Phase 2: re-encrypt with the NEW password, verify, overwrite.
    for (final entry in decrypted.entries) {
      final encrypted = encryptBytes(entry.value, newPassword, salt);
      final check = decryptBytes(encrypted, newPassword, salt);
      if (!bytesEqual(check, entry.value)) {
        throw const FormatException('Re-encryption verification failed');
      }
      await entry.key.writeAsBytes(encrypted, flush: true);
    }
  }
}
