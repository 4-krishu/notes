import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../security/vault_crypto.dart';
import '../security/vault_prefs.dart';
import 'vault_home_screen.dart';
import 'vault_theme.dart';

class VaultLockScreen extends StatefulWidget {
  const VaultLockScreen({super.key});

  @override
  State<VaultLockScreen> createState() => _VaultLockScreenState();
}

class _VaultLockScreenState extends State<VaultLockScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final TextEditingController _answerController = TextEditingController();

  late Box settingsBox;
  late String salt;

  bool isFirstTime = false;
  bool obscure = true;

  /// True while a (slow) PBKDF2 derivation runs in the background.
  bool _unlocking = false;

  String? savedHash;
  String? savedQuestion;
  String? savedAnswerHash;
  String? decoyHash;

  static const int minPasswordLength = 4;

  // --- biometric unlock ---
  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const String _securePwKey = 'vault_password';
  bool _biometricAvailable = false;
  bool _biometricPrompted = false;

  // --- break-in lockout: 5s, 15s, 30s, 60s ---
  static const List<int> _lockoutDelays = [5, 15, 30, 60];

  final List<String> questions = [
    "What was your first school?",
    "What is your childhood nickname?",
    "What is your favorite teacher's name?",
    "What is your best friend's name?",
    "What is your favorite food?",
    "What city were you born in?",
    "What is your pet's name?",
    "What is your favorite movie?",
    "What is your dream job?",
    "What is your favorite color?",
    "What is your mother's name?",
    "What is your father's name?",
  ];

  String selectedQuestion = "What was your first school?";

  @override
  void initState() {
    super.initState();
    settingsBox = Hive.box('settings');
    salt = VaultCrypto.getOrCreateSalt(settingsBox);

    // One-time migration: old plaintext password/answer -> salted hashes.
    final oldPlainPassword = settingsBox.get('vault_password');
    if (oldPlainPassword != null &&
        settingsBox.get(VaultCrypto.passwordHashKey) == null) {
      settingsBox.put(
        VaultCrypto.passwordHashKey,
        VaultCrypto.hashPassword(oldPlainPassword as String, salt),
      );
      settingsBox.delete('vault_password');
    }
    final oldPlainAnswer = settingsBox.get('vault_answer');
    if (oldPlainAnswer != null &&
        settingsBox.get(VaultCrypto.answerHashKey) == null) {
      settingsBox.put(
        VaultCrypto.answerHashKey,
        VaultCrypto.hashAnswer(oldPlainAnswer as String, salt),
      );
      settingsBox.delete('vault_answer');
    }

    savedHash = settingsBox.get(VaultCrypto.passwordHashKey) as String?;
    savedQuestion = settingsBox.get('vault_question') as String?;
    savedAnswerHash = settingsBox.get(VaultCrypto.answerHashKey) as String?;
    decoyHash = VaultPrefs.getString(VaultPrefs.decoyHash);

    isFirstTime = savedHash == null;

    if (!isFirstTime &&
        VaultPrefs.getBool(VaultPrefs.biometricEnabled)) {
      _checkBiometrics();
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Biometric unlock
  // ------------------------------------------------------------------

  Future<void> _checkBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      if (!mounted) return;
      setState(() => _biometricAvailable = canCheck && supported);
      if (_biometricAvailable && !_biometricPrompted) {
        _biometricPrompted = true;
        // Let the UI settle before prompting.
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) _biometricUnlock(auto: true);
      }
    } catch (_) {
      // Biometrics unavailable; password flow still works.
    }
  }

  Future<void> _biometricUnlock({bool auto = false}) async {
    // Respect the lockout: biometrics don't bypass break-in protection.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < VaultPrefs.getInt(VaultPrefs.lockoutUntilMs)) return;

    bool ok = false;
    try {
      ok = await _localAuth.authenticate(
        localizedReason: 'Unlock your vault',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      if (!auto && mounted) _showSnack("Biometric unlock failed");
      return;
    }

    final stored = await _secureStorage.read(key: _securePwKey);
    if (stored == null || stored.isEmpty) {
      if (mounted) {
        _showSnack("No saved unlock found — enter your password");
      }
      return;
    }
    // The stored password may be stale (e.g. changed on another screen).
    final verified = await VaultCrypto.verifyPasswordAsync(
        stored, salt, savedHash ?? '');
    if (verified == null) {
      await _secureStorage.delete(key: _securePwKey);
      if (mounted) {
        _showSnack("Saved unlock is outdated — enter your password");
      }
      return;
    }

    await _finishUnlock(stored, verified.key, verified.wasLegacy,
        decoy: false);
  }

  // ------------------------------------------------------------------
  // Password submit: real password, decoy password, or wrong attempt.
  // Accepts both the current PBKDF2 hashes and legacy pre-Phase-B hashes;
  // a legacy match triggers a one-time transparent key migration.
  // ------------------------------------------------------------------

  Future<void> _submit() async {
    final pass = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pass.isEmpty) return;

    if (pass.length < minPasswordLength) {
      _showSnack("Password must be at least $minPasswordLength characters");
      return;
    }

    if (isFirstTime) {
      if (pass != confirm) {
        _showSnack("Passwords do not match");
        return;
      }

      if (_answerController.text.trim().isEmpty) {
        _showSnack("Answer required");
        return;
      }

      setState(() => _unlocking = true);
      try {
        final answerText = _answerController.text;
        // Derive both in the background (each ~1s); the spinner is up.
        final results = await Future.wait([
          VaultCrypto.deriveKeyAsync(pass, salt),
          VaultCrypto.deriveKeyAsync(
              answerText.trim().toLowerCase(), salt),
        ]);
        final key = results[0];
        // Store only hashes, never the plaintext password/answer.
        settingsBox.put(
          VaultCrypto.passwordHashKey,
          VaultCrypto.hashKey(key),
        );
        settingsBox.put('vault_question', selectedQuestion);
        settingsBox.put(
          VaultCrypto.answerHashKey,
          VaultCrypto.hashKey(results[1]),
        );
        _openVault(key, decoy: false);
      } finally {
        if (mounted) setState(() => _unlocking = false);
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final lockedUntil = VaultPrefs.getInt(VaultPrefs.lockoutUntilMs);
    if (now < lockedUntil) {
      final secs = ((lockedUntil - now) / 1000).ceil();
      _showSnack("Too many attempts. Try again in $secs s");
      return;
    }

    // PBKDF2 verification takes ~1s: run it off the UI thread with the
    // button showing a spinner. The legacy path is microseconds.
    setState(() => _unlocking = true);
    try {
      final verified = await VaultCrypto.verifyPasswordAsync(
          pass, salt, savedHash ?? '');
      if (verified != null) {
        await _finishUnlock(pass, verified.key, verified.wasLegacy,
            decoy: false);
        return;
      }
      if (decoyHash != null) {
        final decoyVerified =
            await VaultCrypto.verifyPasswordAsync(pass, salt, decoyHash!);
        if (decoyVerified != null) {
          await _finishUnlock(pass, decoyVerified.key,
              decoyVerified.wasLegacy,
              decoy: true);
          return;
        }
      }
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
    _onWrongPassword();
  }

  /// Common post-verification path for password and biometric unlocks.
  /// When the stored hash used the legacy pre-Phase-B scheme, every vault
  /// file is re-encrypted to the new stretched key first (one-time).
  Future<void> _finishUnlock(
    String pass,
    Uint8List key,
    bool wasLegacy, {
    required bool decoy,
  }) async {
    if (wasLegacy) {
      _showUpgradingDialog();
      try {
        final docs = await getApplicationDocumentsDirectory();
        final root =
            decoy ? '${docs.path}/vault_decoy' : '${docs.path}/vault';
        await VaultCrypto.rekey(
          vaultRoot: root,
          oldKey: VaultCrypto.deriveKeyLegacy(pass, salt),
          newKey: key,
        );
        // Store the new-scheme hash going forward.
        final newHash = VaultCrypto.hashPassword(pass, salt);
        if (decoy) {
          VaultPrefs.setString(VaultPrefs.decoyHash, newHash);
          decoyHash = newHash;
        } else {
          settingsBox.put(VaultCrypto.passwordHashKey, newHash);
          savedHash = newHash;
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context); // close upgrading dialog
          _showSnack("Security upgrade failed: $e");
        }
        return;
      }
      if (mounted) Navigator.pop(context); // close upgrading dialog
    }

    _onSuccessfulUnlock(pass, key, decoy: decoy);
  }

  /// Blocking "upgrading" dialog shown during the one-time key migration.
  /// The caller closes it via Navigator.pop.
  void _showUpgradingDialog() {
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          backgroundColor: VaultTheme.surface,
          content: const Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(
                child: Text(
                  "Upgrading vault security…",
                  style: TextStyle(color: VaultTheme.textPrimary),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _onSuccessfulUnlock(String pass, Uint8List key,
      {required bool decoy}) {
    VaultPrefs.setInt(VaultPrefs.failedAttempts, 0);
    VaultPrefs.setInt(VaultPrefs.lockoutUntilMs, 0);
    // Keep the secure-storage copy in sync so biometric unlock keeps
    // working after a password change.
    if (!decoy) {
      if (VaultPrefs.getBool(VaultPrefs.biometricEnabled)) {
        _secureStorage.write(key: _securePwKey, value: pass);
      } else {
        _secureStorage.delete(key: _securePwKey);
      }
    }
    _openVault(key, decoy: decoy);
  }

  void _onWrongPassword() {
    final attempts = VaultPrefs.getInt(VaultPrefs.failedAttempts) + 1;
    VaultPrefs.setInt(VaultPrefs.failedAttempts, attempts);

    final delayIndex = attempts - 1 < _lockoutDelays.length
        ? attempts - 1
        : _lockoutDelays.length - 1;
    VaultPrefs.setInt(
      VaultPrefs.lockoutUntilMs,
      DateTime.now().millisecondsSinceEpoch +
          _lockoutDelays[delayIndex] * 1000,
    );

    if (attempts % 3 == 0) {
      // Fire and forget: the camera must never block the UI.
      _captureIntruderSelfie();
    }
    _showSnack("Wrong password");
  }

  /// Silently captures a front-camera photo after repeated wrong attempts
  /// and stores it ENCRYPTED in the vault's hidden .intruder/ folder.
  /// Never throws: a camera failure must not break the lock screen.
  Future<void> _captureIntruderSelfie() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) return;

      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        front,
        ResolutionPreset.low,
        enableAudio: false,
      );
      await controller.initialize();
      final pic = await controller.takePicture();
      await controller.dispose();

      final bytes = await File(pic.path).readAsBytes();
      try {
        await File(pic.path).delete();
      } catch (_) {}

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/vault/.intruder');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final encrypted = VaultCrypto.encryptWithKey(
        bytes,
        VaultCrypto.intruderKey(salt),
      );
      await File(
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg.enc',
      ).writeAsBytes(encrypted, flush: true);
    } catch (_) {
      // Camera unavailable, denied, or failed: stay silent.
    }
  }

  void _openVault(Uint8List vaultKey, {required bool decoy}) {
    // The derived key lives in memory only, for file encryption.
    // The plaintext password is never passed beyond the lock screen.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => VaultHomeScreen(
          vaultKey: vaultKey,
          decoy: decoy,
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _forgotPassword() {
    if (savedQuestion == null) return;

    _answerController.clear();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: VaultTheme.surface,
          title: Text(
            savedQuestion!,
            style: const TextStyle(
              fontSize: 16,
              color: VaultTheme.textPrimary,
            ),
          ),
          content: TextField(
            controller: _answerController,
            style:
                const TextStyle(color: VaultTheme.textPrimary),
            decoration:
                VaultTheme.inputDecoration("Answer"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final input = _answerController.text.trim();
                final checked = await VaultCrypto.verifyAnswerAsync(
                    input, salt, savedAnswerHash);
                if (checked.ok) {
                  // Upgrade a legacy answer hash to the PBKDF2 scheme.
                  if (checked.wasLegacy) {
                    settingsBox.put(
                      VaultCrypto.answerHashKey,
                      VaultCrypto.hashAnswer(input, salt),
                    );
                    savedAnswerHash = settingsBox
                        .get(VaultCrypto.answerHashKey) as String?;
                  }
                  // Wipe the old hash; the fresh lock screen will ask for
                  // a new password (isFirstTime == true). Biometric unlock
                  // is disabled too: its stored password is now stale.
                  settingsBox.delete(VaultCrypto.passwordHashKey);
                  VaultPrefs.setBool(
                      VaultPrefs.biometricEnabled, false);
                  await _secureStorage.delete(key: _securePwKey);
                  VaultPrefs.setInt(VaultPrefs.failedAttempts, 0);
                  VaultPrefs.setInt(VaultPrefs.lockoutUntilMs, 0);
                  Navigator.pop(dialogContext);
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => const VaultLockScreen(),
                    ),
                  );
                } else {
                  _showSnack("Wrong answer");
                }
              },
              child: const Text("Verify"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VaultTheme.background,
      appBar: AppBar(
        backgroundColor: VaultTheme.background,
        elevation: 0,
        title: Text(isFirstTime ? "Set Vault Password" : "Unlock Vault"),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: VaultTheme.cardDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.lock,
                    size: 56,
                    color: VaultTheme.accent,
                  ),
                  const SizedBox(height: 20),

                  TextField(
                    controller: _passwordController,
                    obscureText: obscure,
                    style:
                        const TextStyle(color: VaultTheme.textPrimary),
                    decoration: VaultTheme.inputDecoration("Password")
                        .copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: VaultTheme.textSecondary,
                        ),
                        onPressed: () {
                          setState(() {
                            obscure = !obscure;
                          });
                        },
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),

                  const SizedBox(height: 15),

                  if (isFirstTime) ...[
                    TextField(
                      controller: _confirmController,
                      obscureText: obscure,
                      style: const TextStyle(
                          color: VaultTheme.textPrimary),
                      decoration: VaultTheme.inputDecoration(
                          "Confirm Password"),
                    ),
                    const SizedBox(height: 15),

                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: selectedQuestion,
                      dropdownColor: VaultTheme.surfaceLight,
                      style: const TextStyle(
                          color: VaultTheme.textPrimary),
                      items: questions.map((q) {
                        return DropdownMenuItem<String>(
                          value: q,
                          child: Text(
                            q,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        setState(() {
                          selectedQuestion = v!;
                        });
                      },
                      decoration: VaultTheme.inputDecoration(
                          "Security Question"),
                    ),

                    const SizedBox(height: 15),

                    TextField(
                      controller: _answerController,
                      style: const TextStyle(
                          color: VaultTheme.textPrimary),
                      decoration:
                          VaultTheme.inputDecoration("Answer"),
                    ),

                    const SizedBox(height: 15),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VaultTheme.accent,
                        foregroundColor: Colors.white,
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _unlocking ? null : _submit,
                      child: _unlocking
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              isFirstTime ? "Set Password" : "Unlock",
                            ),
                    ),
                  ),

                  if (!isFirstTime && _biometricAvailable) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: VaultTheme.accent,
                          side: const BorderSide(
                              color: VaultTheme.accent),
                          padding: const EdgeInsets.symmetric(
                              vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _biometricUnlock(),
                        icon: const Icon(Icons.fingerprint),
                        label: const Text("Use fingerprint / face"),
                      ),
                    ),
                  ],

                  const SizedBox(height: 10),

                  if (!isFirstTime)
                    TextButton(
                      onPressed: _forgotPassword,
                      style: TextButton.styleFrom(
                        foregroundColor: VaultTheme.accent,
                      ),
                      child: const Text("Forgot Password?"),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
