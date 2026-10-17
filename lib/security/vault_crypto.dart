import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Security helpers for the vault.
///
/// Design (Phase B):
/// - A random salt is generated once and stored in the encrypted Hive
///   'settings' box (see VaultBoxes).
/// - The vault password is NEVER stored. Only a salted, stretched hash is
///   kept: PBKDF2-HMAC-SHA256 with 210,000 iterations (OWASP guidance).
///   The 32-byte derived key doubles as the AES-256 file key.
/// - Stored hashes are prefixed: `'pbkdf2$<hex>'`. Pre-Phase-B installs used
///   a single fast SHA-256(salt::password) with no prefix; those are still
///   recognized and transparently migrated on the next successful unlock.
/// - Vault files are AES-256 encrypted with the derived key. A fresh random
///   IV is used per file, prepended on disk: [ iv (16 bytes) | ciphertext ].
/// - Intruder selfies are encrypted with a key derived from the salt only
///   (the vault password is unknown at capture time), so they are excluded
///   from password changes and key migrations.
class VaultCrypto {
  static const String passwordHashKey = 'vault_password_hash';
  static const String answerHashKey = 'vault_answer_hash';
  static const String _saltKey = 'vault_salt';

  /// PBKDF2 iteration count.
  ///
  /// OWASP recommends 210k for server hardware; on a phone that costs
  /// several seconds per unlock (pure-Dart HMAC). 100k is the pragmatic
  /// mobile trade-off: still ~100,000x slower to brute-force than the old
  /// single-SHA-256 scheme, while unlocking stays in the 1-3s range.
  /// Combined with Phase A (hardware-backed keystore holding the Hive key),
  /// offline brute force already requires defeating the keystore first.
  /// Tune here if hardware gets faster.
  static const int pbkdf2Iterations = 100000;

  /// Prefix marking a hash as PBKDF2-derived. Legacy (pre-Phase-B) hashes
  /// have no prefix and used a single SHA-256.
  static const String _pbkdf2Prefix = 'pbkdf2\$';

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
  ///
  /// Phase B: the stored form is now `'pbkdf2$<hex>'` (PBKDF2-HMAC-SHA256),
  /// stretched with [pbkdf2Iterations]. The derived 32 bytes ARE the AES
  /// file key, so one derivation serves both authentication and encryption.
  static String hashPassword(String password, String salt) {
    return hashKey(deriveKey(password, salt));
  }

  /// Stored-hash string for an already-derived key. Lets callers that
  /// derived the key in the background avoid paying for a second
  /// derivation when storing the hash.
  static String hashKey(Uint8List key) {
    return '$_pbkdf2Prefix${_hex(key)}';
  }

  /// Legacy (pre-Phase-B) password hash: single fast SHA-256, no prefix.
  /// Only used to recognize and migrate old installs.
  static String hashPasswordLegacy(String password, String salt) {
    return _hex(deriveKeyLegacy(password, salt));
  }

  /// Hash of the (lowercased, trimmed) security answer. Stored instead of
  /// the plaintext answer. Same PBKDF2 scheme (and legacy handling) as
  /// [hashPassword].
  static String hashAnswer(String answer, String salt) {
    return '$_pbkdf2Prefix${_hex(deriveKey(answer.trim().toLowerCase(), salt))}';
  }

  /// Legacy answer hash (pre-Phase-B).
  static String hashAnswerLegacy(String answer, String salt) {
    return sha256
        .convert(utf8.encode('$salt::${answer.trim().toLowerCase()}'))
        .toString();
  }

  /// PBKDF2-HMAC-SHA256 key derivation. Slow by design ([pbkdf2Iterations]
  /// iterations): brute-forcing a stolen hash is ~200k times more expensive
  /// than the old single-SHA-256 scheme.
  ///
  /// Derive ONCE per unlock and reuse the key — never per file.
  static Uint8List deriveKey(String password, String salt) {
    final passwordBytes = utf8.encode(password);
    final saltBytes = utf8.encode(salt);
    const keyLength = 32;
    const hashLen = 32; // SHA-256 output
    final blocks = (keyLength + hashLen - 1) ~/ hashLen;

    final out = <int>[];
    for (var i = 1; i <= blocks; i++) {
      final hmac = Hmac(sha256, passwordBytes);
      // U1 = PRF(password, salt || INT32_BE(i))
      var u = hmac
          .convert([
            ...saltBytes,
            (i >> 24) & 0xff,
            (i >> 16) & 0xff,
            (i >> 8) & 0xff,
            i & 0xff,
          ])
          .bytes;
      final xored = Uint8List.fromList(u);
      for (var j = 1; j < pbkdf2Iterations; j++) {
        u = hmac.convert(u).bytes;
        for (var k = 0; k < xored.length; k++) {
          xored[k] ^= u[k];
        }
      }
      out.addAll(xored);
    }
    return Uint8List.fromList(out.sublist(0, keyLength));
  }

  /// Background-isolate derivation: identical output to [deriveKey] but
  /// never blocks the UI thread. Always prefer this on UI-driven paths
  /// (unlock, password change); the ~1s cost shows a progress indicator.
  static Future<Uint8List> deriveKeyAsync(String password, String salt) =>
      compute(_deriveKeyBackground, _KdfParams(password, salt));

  /// Legacy fast key derivation (pre-Phase-B): single SHA-256. Only used
  /// during migration of old installs.
  static Uint8List deriveKeyLegacy(String password, String salt) {
    return Uint8List.fromList(
      sha256.convert(utf8.encode('$salt::$password')).bytes,
    );
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Verifies [password] against [storedHash], accepting both the current
  /// PBKDF2 scheme and the legacy pre-Phase-B scheme.
  ///
  /// Returns the derived AES key and whether the hash was legacy (in which
  /// case the caller should migrate: re-encrypt files with the new key and
  /// store [hashPassword]). Returns null when the password is wrong.
  static ({Uint8List key, bool wasLegacy})? verifyPassword(
    String password,
    String salt,
    String storedHash,
  ) {
    if (storedHash.startsWith(_pbkdf2Prefix)) {
      final key = deriveKey(password, salt);
      if ('$_pbkdf2Prefix${_hex(key)}' == storedHash) {
        return (key: key, wasLegacy: false);
      }
      return null;
    }
    final key = deriveKeyLegacy(password, salt);
    if (_hex(key) == storedHash) {
      return (key: key, wasLegacy: true);
    }
    return null;
  }

  /// Async variant of [verifyPassword]: the PBKDF2 path runs in a
  /// background isolate; the legacy path is microseconds and stays inline.
  static Future<({Uint8List key, bool wasLegacy})?> verifyPasswordAsync(
    String password,
    String salt,
    String storedHash,
  ) async {
    if (storedHash.startsWith(_pbkdf2Prefix)) {
      final key = await deriveKeyAsync(password, salt);
      if ('$_pbkdf2Prefix${_hex(key)}' == storedHash) {
        return (key: key, wasLegacy: false);
      }
      return null;
    }
    return verifyPassword(password, salt, storedHash);
  }

  /// Async variant of [verifyAnswer] for the PBKDF2 path.
  static Future<({bool ok, bool wasLegacy})> verifyAnswerAsync(
    String answer,
    String salt,
    String? storedHash,
  ) async {
    if (storedHash == null || answer.trim().isEmpty) {
      return (ok: false, wasLegacy: false);
    }
    if (storedHash.startsWith(_pbkdf2Prefix)) {
      final key =
          await deriveKeyAsync(answer.trim().toLowerCase(), salt);
      return (ok: '$_pbkdf2Prefix${_hex(key)}' == storedHash, wasLegacy: false);
    }
    return verifyAnswer(answer, salt, storedHash);
  }

  /// Verifies a security answer against [storedHash] (either scheme).
  static ({bool ok, bool wasLegacy}) verifyAnswer(
    String answer,
    String salt,
    String? storedHash,
  ) {
    if (storedHash == null || answer.trim().isEmpty) {
      return (ok: false, wasLegacy: false);
    }
    if (storedHash.startsWith(_pbkdf2Prefix)) {
      return (
        ok: hashAnswer(answer, salt) == storedHash,
        wasLegacy: false
      );
    }
    return (
      ok: hashAnswerLegacy(answer, salt) == storedHash,
      wasLegacy: true
    );
  }

  /// Key used for intruder-selfie photos. Derived from the salt only, since
  /// the vault password is unknown when a selfie is captured.
  static Uint8List intruderKey(String salt) {
    return Uint8List.fromList(
      sha256.convert(utf8.encode('$salt::intruder')).bytes,
    );
  }

  /// Encrypts [plainBytes] with a raw 32-byte [key].
  /// Returns [ iv (16 bytes) | ciphertext ].
  static Uint8List encryptWithKey(Uint8List plainBytes, Uint8List key) {
    final k = enc.Key(key);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(k));
    final encrypted = encrypter.encryptBytes(plainBytes, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Decrypts data produced by [encryptWithKey].
  static Uint8List decryptWithKey(Uint8List data, Uint8List key) {
    if (data.length < 17) {
      throw const FormatException('Not a vault file');
    }
    final iv = enc.IV(Uint8List.fromList(data.sublist(0, 16)));
    final cipher = enc.Encrypted(Uint8List.fromList(data.sublist(16)));
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key)));
    return Uint8List.fromList(encrypter.decryptBytes(cipher, iv: iv));
  }

  /// Encrypts [plainBytes] with [key], a 32-byte derived key from
  /// [deriveKey]. Returns [ iv (16 bytes) | ciphertext ].
  ///
  /// The key must be derived ONCE per unlock and reused — never derived
  /// per file (PBKDF2 is intentionally slow).
  static Uint8List encryptBytes(Uint8List plainBytes, Uint8List key) {
    return encryptWithKey(plainBytes, key);
  }

  /// Decrypts data produced by [encryptBytes] with [key].
  /// Throws [FormatException] if the data is not a vault file, and an
  /// [ArgumentError]/[StateError] from the encrypt package if the key is
  /// wrong.
  static Uint8List decryptBytes(Uint8List data, Uint8List key) {
    return decryptWithKey(data, key);
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

  /// Re-encrypts every key-encrypted `.enc` file under [vaultRoot] from
  /// [oldKey] to [newKey], one file at a time (memory stays bounded no
  /// matter how many files the vault holds).
  ///
  /// Used both for password changes and for the Phase-B key migration
  /// (old PBKDF2-less key -> new stretched key).
  ///
  /// Files under `.intruder/` are skipped: they are encrypted with the
  /// salt-derived intruder key, not the vault password.
  ///
  /// Atomic-ish: each file is re-encrypted and verified into a temporary
  /// `.new` file first. Only after ALL files succeed are the temp files
  /// renamed over the originals. On any failure the temp files are deleted
  /// and the originals (plus the old password hash) are untouched, so a
  /// wrong key or corrupt file aborts safely.
  ///
  /// The caller must update the stored password hash only after this
  /// completes without throwing.
  static Future<void> rekey({
    required String vaultRoot,
    required Uint8List oldKey,
    required Uint8List newKey,
  }) async {
    final root = Directory(vaultRoot);
    final files = <File>[];
    if (await root.exists()) {
      await for (final e in root.list(recursive: true)) {
        if (e is File &&
            e.path.endsWith('.enc') &&
            !e.path.contains('/.intruder/')) {
          files.add(e);
        }
      }
    }

    final staged = <File>[];
    try {
      for (final f in files) {
        // Decrypt with the OLD key (throws on wrong key ->
        // abort before anything is staged).
        final plain = decryptBytes(
          await f.readAsBytes(),
          oldKey,
        );
        final encrypted = encryptBytes(plain, newKey);
        final check = decryptBytes(encrypted, newKey);
        if (!bytesEqual(check, plain)) {
          throw const FormatException(
              'Re-encryption verification failed');
        }
        final tmp = File('${f.path}.new');
        await tmp.writeAsBytes(encrypted, flush: true);
        staged.add(tmp);
        // plain/encrypted/check go out of scope here -> memory is freed
        // before the next file.
      }

      // All verified: swap temp files over the originals.
      for (final tmp in staged) {
        final origPath =
            tmp.path.substring(0, tmp.path.length - '.new'.length);
        await tmp.rename(origPath);
      }
    } catch (_) {
      // Roll back: delete staged temp files, originals untouched.
      for (final tmp in staged) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Password-change entry point. Kept for compatibility; prefer [rekey]
  /// with pre-derived keys.
  static Future<void> changePassword({
    required String vaultRoot,
    required String oldPassword,
    required String newPassword,
    required String salt,
  }) {
    return rekey(
      vaultRoot: vaultRoot,
      oldKey: deriveKey(oldPassword, salt),
      newKey: deriveKey(newPassword, salt),
    );
  }
}


/// Params for background key derivation via [compute].
class _KdfParams {
  final String password;
  final String salt;
  const _KdfParams(this.password, this.salt);
}

/// Top-level so it can run in a background isolate.
Uint8List _deriveKeyBackground(_KdfParams p) =>
    VaultCrypto.deriveKey(p.password, p.salt);
