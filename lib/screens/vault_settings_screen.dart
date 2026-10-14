import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

import '../security/vault_crypto.dart';
import '../security/vault_prefs.dart';
import '../security/vault_storage.dart';
import 'vault_intruder_log_screen.dart';
import 'vault_lock_screen.dart';
import 'vault_theme.dart';

/// Vault settings: unlock methods, privacy, password management.
///
/// In decoy mode the sensitive sections (decoy password, intruder log,
/// backup) are hidden so the fake vault looks ordinary.
class VaultSettingsScreen extends StatefulWidget {
  final String password;
  final bool decoy;
  final void Function(String newPassword) onPasswordChanged;

  const VaultSettingsScreen({
    super.key,
    required this.password,
    required this.decoy,
    required this.onPasswordChanged,
  });

  @override
  State<VaultSettingsScreen> createState() => _VaultSettingsScreenState();
}

class _VaultSettingsScreenState extends State<VaultSettingsScreen> {
  late Box settingsBox;
  late String _salt;
  late String _password;
  late VaultStorage _storage;

  bool _bioSupported = false;
  bool _bioEnabled = false;
  bool _shakeEnabled = false;
  int _autoLockSecs = 0;
  bool _hasDecoy = false;
  int _intruderCount = 0;

  static const String _securePwKey = 'vault_password';
  static const Map<int, String> _autoLockOptions = {
    0: 'Off',
    30: '30 seconds',
    60: '1 minute',
    300: '5 minutes',
  };

  @override
  void initState() {
    super.initState();
    _password = widget.password;
    _storage = VaultStorage(decoy: widget.decoy);
    settingsBox = Hive.box('settings');
    _salt = VaultCrypto.getOrCreateSalt(settingsBox);
    _bioEnabled = VaultPrefs.getBool(VaultPrefs.biometricEnabled);
    _shakeEnabled = VaultPrefs.getBool(VaultPrefs.shakeLockEnabled);
    _autoLockSecs = VaultPrefs.getInt(VaultPrefs.autoLockSeconds);
    _hasDecoy = VaultPrefs.getString(VaultPrefs.decoyHash) != null;
    _checkBioSupport();
    _loadIntruderCount();
  }

  Future<void> _checkBioSupport() async {
    try {
      final auth = LocalAuthentication();
      final ok = await auth.canCheckBiometrics &&
          await auth.isDeviceSupported();
      if (mounted) setState(() => _bioSupported = ok);
    } catch (_) {}
  }

  Future<void> _loadIntruderCount() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/vault/.intruder');
      if (!await dir.exists()) return;
      final files = await dir.list().toList();
      final n = files
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .length;
      if (mounted) setState(() => _intruderCount = n);
    } catch (_) {}
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------
  // Biometric toggle
  // ------------------------------------------------------------------

  Future<void> _setBiometric(bool enabled) async {
    if (enabled) {
      bool ok = false;
      try {
        ok = await LocalAuthentication().authenticate(
          localizedReason: 'Confirm it\'s you to enable biometric unlock',
          options: const AuthenticationOptions(
            biometricOnly: true,
            stickyAuth: true,
          ),
        );
      } catch (_) {}
      if (!ok) {
        if (mounted) _snack("Biometric authentication failed");
        return;
      }
      // Store the password in the OS keystore so a biometric success can
      // unlock the vault without asking for the password.
      await const FlutterSecureStorage()
          .write(key: _securePwKey, value: _password);
      if (mounted) _snack("Biometric unlock enabled");
    } else {
      await const FlutterSecureStorage().delete(key: _securePwKey);
    }
    VaultPrefs.setBool(VaultPrefs.biometricEnabled, enabled);
    if (mounted) setState(() => _bioEnabled = enabled);
  }

  // ------------------------------------------------------------------
  // Decoy password
  // ------------------------------------------------------------------

  void _decoyDialog() {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    void disposeAll() {
      currentCtrl.dispose();
      newCtrl.dispose();
      confirmCtrl.dispose();
    }

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: Text(
          _hasDecoy ? "Change Decoy Password" : "Set Decoy Password",
          style: const TextStyle(color: VaultTheme.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Entering the decoy password opens a separate, fake "
                "vault. Your real files stay hidden.",
                style: TextStyle(
                    color: VaultTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currentCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration: VaultTheme.inputDecoration(
                    "Current vault password"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration: VaultTheme.inputDecoration(
                    "New decoy password"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration: VaultTheme.inputDecoration(
                    "Confirm decoy password"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              disposeAll();
              Navigator.pop(dialogContext);
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              final current = currentCtrl.text.trim();
              final newPw = newCtrl.text.trim();
              final confirm = confirmCtrl.text.trim();

              if (VaultCrypto.hashPassword(current, _salt) !=
                  settingsBox.get(VaultCrypto.passwordHashKey)) {
                _snack("Wrong current password");
                return;
              }
              if (newPw.length < 4) {
                _snack("Decoy password must be at least 4 characters");
                return;
              }
              if (newPw != confirm) {
                _snack("Decoy passwords do not match");
                return;
              }
              if (VaultCrypto.hashPassword(newPw, _salt) ==
                  settingsBox.get(VaultCrypto.passwordHashKey)) {
                _snack("Decoy password must differ from the real one");
                return;
              }

              VaultPrefs.setString(
                VaultPrefs.decoyHash,
                VaultCrypto.hashPassword(newPw, _salt),
              );
              disposeAll();
              Navigator.pop(dialogContext);
              setState(() => _hasDecoy = true);
              _snack("Decoy password set");
            },
            child: const Text("Save",
                style: TextStyle(color: VaultTheme.accent)),
          ),
        ],
      ),
    );
  }

  void _removeDecoy() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text("Remove Decoy Password?",
            style: TextStyle(color: VaultTheme.textPrimary)),
        content: const Text(
          "The decoy vault's files stay on disk, but the decoy "
          "password will no longer open them.",
          style: TextStyle(color: VaultTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              VaultPrefs.remove(VaultPrefs.decoyHash);
              Navigator.pop(dialogContext);
              setState(() => _hasDecoy = false);
              _snack("Decoy password removed");
            },
            child: const Text("Remove",
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Change password (real vault, or decoy vault when in decoy mode)
  // ------------------------------------------------------------------

  void _changePassword() {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    void disposeAll() {
      currentCtrl.dispose();
      newCtrl.dispose();
      confirmCtrl.dispose();
    }

    final hashKey =
        widget.decoy ? VaultPrefs.decoyHash : VaultCrypto.passwordHashKey;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: Text(
          widget.decoy
              ? "Change Decoy Password"
              : "Change Password",
          style: const TextStyle(color: VaultTheme.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration:
                    VaultTheme.inputDecoration("Current password"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration:
                    VaultTheme.inputDecoration("New password"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                style:
                    const TextStyle(color: VaultTheme.textPrimary),
                decoration: VaultTheme.inputDecoration(
                    "Confirm new password"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              disposeAll();
              Navigator.pop(dialogContext);
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              final current = currentCtrl.text.trim();
              final newPw = newCtrl.text.trim();
              final confirm = confirmCtrl.text.trim();

              if (newPw.length < 4) {
                _snack("New password must be at least 4 characters");
                return;
              }
              if (newPw != confirm) {
                _snack("New passwords do not match");
                return;
              }
              final storedHash = widget.decoy
                  ? VaultPrefs.getString(VaultPrefs.decoyHash)
                  : settingsBox.get(hashKey) as String?;
              if (storedHash == null ||
                  VaultCrypto.hashPassword(current, _salt) !=
                      storedHash) {
                _snack("Wrong current password");
                return;
              }
              if (!widget.decoy &&
                  VaultCrypto.hashPassword(newPw, _salt) ==
                      VaultPrefs.getString(VaultPrefs.decoyHash)) {
                _snack(
                    "New password must differ from the decoy password");
                return;
              }

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );

              try {
                final root = await _storage.rootPath();
                await VaultCrypto.changePassword(
                  vaultRoot: root,
                  oldPassword: current,
                  newPassword: newPw,
                  salt: _salt,
                );
                if (widget.decoy) {
                  VaultPrefs.setString(VaultPrefs.decoyHash,
                      VaultCrypto.hashPassword(newPw, _salt));
                } else {
                  settingsBox.put(
                    VaultCrypto.passwordHashKey,
                    VaultCrypto.hashPassword(newPw, _salt),
                  );
                  if (VaultPrefs.getBool(
                      VaultPrefs.biometricEnabled)) {
                    await const FlutterSecureStorage().write(
                        key: _securePwKey, value: newPw);
                  }
                }
                setState(() => _password = newPw);
                widget.onPasswordChanged(newPw);
                disposeAll();
                if (mounted) {
                  Navigator.pop(context); // loading
                  Navigator.pop(dialogContext); // dialog
                  _snack("Password changed");
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context); // loading
                  _snack("Couldn't change password: $e");
                }
              }
            },
            child: const Text("Change",
                style: TextStyle(color: VaultTheme.accent)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // UI helpers
  // ------------------------------------------------------------------

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: VaultTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      decoration: VaultTheme.cardDecoration(),
      child: Column(children: children),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon, color: VaultTheme.accent),
      title: Text(title,
          style: const TextStyle(color: VaultTheme.textPrimary)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style:
                  const TextStyle(color: VaultTheme.textSecondary)),
      value: value,
      activeThumbColor: VaultTheme.accent,
      onChanged: onChanged,
    );
  }

  Widget _navTile({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    Color? titleColor,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: titleColor ?? VaultTheme.accent),
      title: Text(title,
          style: TextStyle(
              color: titleColor ?? VaultTheme.textPrimary)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style:
                  const TextStyle(color: VaultTheme.textSecondary)),
      trailing: trailing == null
          ? const Icon(Icons.chevron_right,
              color: VaultTheme.textSecondary)
          : Text(trailing,
              style:
                  const TextStyle(color: VaultTheme.textSecondary)),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VaultTheme.background,
      appBar: AppBar(
        backgroundColor: VaultTheme.background,
        elevation: 0,
        iconTheme:
            const IconThemeData(color: VaultTheme.textPrimary),
        title: const Text(
          "Vault Settings",
          style: TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionTitle("Unlock"),
          _card([
            if (_bioSupported)
              _switchTile(
                icon: Icons.fingerprint,
                title: "Biometric unlock",
                subtitle: "Fingerprint / face instead of password",
                value: _bioEnabled,
                onChanged: _setBiometric,
              ),
            ListTile(
              leading: const Icon(Icons.timer_outlined,
                  color: VaultTheme.accent),
              title: const Text("Auto-lock",
                  style:
                      TextStyle(color: VaultTheme.textPrimary)),
              subtitle: const Text(
                  "Re-lock the vault after being in background",
                  style:
                      TextStyle(color: VaultTheme.textSecondary)),
              trailing: DropdownButton<int>(
                value: _autoLockOptions.containsKey(_autoLockSecs)
                    ? _autoLockSecs
                    : 0,
                dropdownColor: VaultTheme.surfaceLight,
                style: const TextStyle(
                    color: VaultTheme.textPrimary),
                underline: const SizedBox.shrink(),
                items: _autoLockOptions.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  VaultPrefs.setInt(
                      VaultPrefs.autoLockSeconds, v);
                  setState(() => _autoLockSecs = v);
                },
              ),
            ),
          ]),

          _sectionTitle("Privacy"),
          _card([
            _switchTile(
              icon: Icons.vibration,
              title: "Shake to lock",
              subtitle: "Shake the phone firmly to instantly lock",
              value: _shakeEnabled,
              onChanged: (v) {
                VaultPrefs.setBool(VaultPrefs.shakeLockEnabled, v);
                setState(() => _shakeEnabled = v);
              },
            ),
            if (!widget.decoy)
              _navTile(
                icon: Icons.visibility_off_outlined,
                title: "Decoy password",
                subtitle: _hasDecoy
                    ? "Set — opens a fake vault"
                    : "Not set",
                onTap: _decoyDialog,
              ),
            if (!widget.decoy && _hasDecoy)
              _navTile(
                icon: Icons.delete_outline,
                title: "Remove decoy password",
                titleColor: VaultTheme.danger,
                onTap: _removeDecoy,
              ),
            if (!widget.decoy)
              _navTile(
                icon: Icons.camera_front_outlined,
                title: "Intruder log",
                subtitle: "Photos captured on wrong attempts",
                trailing: _intruderCount > 0
                    ? "$_intruderCount"
                    : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const IntruderLogScreen(),
                  ),
                ).then((_) => _loadIntruderCount()),
              ),
          ]),

          _sectionTitle("Security"),
          _card([
            _navTile(
              icon: Icons.password_outlined,
              title: widget.decoy
                  ? "Change decoy password"
                  : "Change password",
              onTap: _changePassword,
            ),
            _navTile(
              icon: Icons.logout_outlined,
              title: "Lock vault now",
              onTap: () => Navigator.of(context)
                  .pushAndRemoveUntil(
                MaterialPageRoute(
                    builder: (_) => const VaultLockScreen()),
                (route) => route.isFirst,
              ),
            ),
          ]),

          const SizedBox(height: 24),
          const Center(
            child: Text(
              "The vault password is never stored.\nOnly its salted hash is kept.",
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: VaultTheme.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
