import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

class VaultLockScreen extends StatefulWidget {
  const VaultLockScreen({super.key});

  @override
  State<VaultLockScreen> createState() => _VaultLockScreenState();
}

class _VaultLockScreenState extends State<VaultLockScreen> {
  final TextEditingController _controller = TextEditingController();

  late Box settingsBox;

  bool isFirstTime = false;
  String? savedPassword;

  @override
  void initState() {
    super.initState();
    settingsBox = Hive.box('settings');

    savedPassword = settingsBox.get('vault_password');

    isFirstTime = savedPassword == null;
  }

  void _handleSubmit() {
    final input = _controller.text.trim();

    if (input.isEmpty) return;

    if (isFirstTime) {
      settingsBox.put('vault_password', input);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password set successfully')),
      );

      Navigator.pop(context);
    } else {
      if (input == savedPassword) {
        Navigator.pop(context); // later we go to VaultHome
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong password')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isFirstTime ? 'Set Vault Password' : 'Enter Vault Password'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 40),

            TextField(
              controller: _controller,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Enter password',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _handleSubmit,
                child: Text(isFirstTime ? 'Set Password' : 'Unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}