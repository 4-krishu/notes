import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../security/vault_crypto.dart';
import 'vault_home_screen.dart';

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

  String? savedHash;
  String? savedQuestion;
  String? savedAnswerHash;

  static const int minPasswordLength = 4;

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

    isFirstTime = savedHash == null;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  void _submit() {
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

      // Store only hashes, never the plaintext password/answer.
      settingsBox.put(
        VaultCrypto.passwordHashKey,
        VaultCrypto.hashPassword(pass, salt),
      );
      settingsBox.put('vault_question', selectedQuestion);
      settingsBox.put(
        VaultCrypto.answerHashKey,
        VaultCrypto.hashAnswer(_answerController.text, salt),
      );

      _openVault(pass);
    } else {
      final hash = VaultCrypto.hashPassword(pass, salt);
      if (hash == savedHash) {
        _openVault(pass);
      } else {
        _showSnack("Wrong password");
      }
    }
  }

  void _openVault(String password) {
    // The plaintext password lives in memory only, for file encryption.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => VaultHomeScreen(password: password),
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
          title: Text(
            savedQuestion!,
            style: const TextStyle(fontSize: 16),
          ),
          content: TextField(
            controller: _answerController,
            decoration: const InputDecoration(hintText: "Answer"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                final input = _answerController.text.trim();
                final ok = input.isNotEmpty &&
                    VaultCrypto.hashAnswer(input, salt) == savedAnswerHash;
                if (ok) {
                  // Wipe the old hash; the fresh lock screen will ask for
                  // a new password (isFirstTime == true).
                  settingsBox.delete(VaultCrypto.passwordHashKey);
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
      backgroundColor: Colors.pink.shade50,
      appBar: AppBar(
        backgroundColor: Colors.pink,
        title: Text(isFirstTime ? "Set Vault Password" : "Unlock Vault"),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(blurRadius: 10, color: Colors.black12)
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock, size: 60, color: Colors.pink),
                  const SizedBox(height: 20),

                  TextField(
                    controller: _passwordController,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: "Password",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () {
                          setState(() {
                            obscure = !obscure;
                          });
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 15),

                  if (isFirstTime) ...[
                    TextField(
                      controller: _confirmController,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: "Confirm Password",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),

                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: selectedQuestion,
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
                      decoration: InputDecoration(
                        labelText: "Security Question",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),

                    const SizedBox(height: 15),

                    TextField(
                      controller: _answerController,
                      decoration: InputDecoration(
                        labelText: "Answer",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),

                    const SizedBox(height: 15),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.pink,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _submit,
                      child: Text(
                        isFirstTime ? "Set Password" : "Unlock",
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  if (!isFirstTime)
                    TextButton(
                      onPressed: _forgotPassword,
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
