import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/note_model.dart';
import 'screens/notes_screen.dart';
import 'security/vault_boxes.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  // 🔥 Register adapter
  Hive.registerAdapter(NoteAdapter());

  // 🔥 OPEN BOX BEFORE RUNNING APP
  await Hive.openBox<Note>('notesBox');
  // Vault settings live in an AES-256 encrypted box. On first launch after
  // this change, the old plaintext box is migrated automatically.
  // (The plain notes box stays unencrypted by design: regular notes were
  // never meant to be secret; only the vault is.)
  await VaultBoxes.openSettings();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: NotesScreen(),
    );
  }
}
