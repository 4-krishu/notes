import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'vault_home_screen.dart'; // ✅ IMPORTANT

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

  bool isFirstTime = false;
  bool obscure = true;

  String? savedPassword;
  String? savedQuestion;
  String? savedAnswer;

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

    savedPassword = settingsBox.get('vault_password');
    savedQuestion = settingsBox.get('vault_question');
    savedAnswer = settingsBox.get('vault_answer');

    isFirstTime = savedPassword == null;
  }

  void _submit() {
    final pass = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pass.isEmpty) return;

    if (isFirstTime) {
      if (pass != confirm) {
        _showSnack("Passwords do not match");
        return;
      }

      if (_answerController.text.trim().isEmpty) {
        _showSnack("Answer required");
        return;
      }

      settingsBox.put('vault_password', pass);
      settingsBox.put('vault_question', selectedQuestion);
      settingsBox.put('vault_answer', _answerController.text.trim());

      // ✅ FIX HERE
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const VaultHomeScreen(),
        ),
      );
    } else {
      if (pass == savedPassword) {
        // ✅ FIX HERE
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const VaultHomeScreen(),
          ),
        );
      } else {
        _showSnack("Wrong password");
      }
    }
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
      builder: (_) {
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
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (_answerController.text.trim() == savedAnswer) {
                  settingsBox.delete('vault_password');

                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => const VaultLockScreen(),
                    ),
                  );

                  setState(() {
                    isFirstTime = true;
                  });

                  _showSnack("Set new password");
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