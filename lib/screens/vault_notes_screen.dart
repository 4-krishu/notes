import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../security/vault_crypto.dart';
import '../security/vault_storage.dart';
import 'vault_theme.dart';

/// One encrypted vault text note. Stored as "<id>.note.enc" inside the
/// vault's hidden .notes/ folder; the JSON payload is AES-encrypted with
/// the vault password, exactly like files.
class _VaultNote {
  final String id; // e.g. "1730000000000"
  String title;
  String body;
  int updatedAt; // ms since epoch

  _VaultNote({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
  });

  String get fileName => '$id.note.enc';
}

class VaultNotesScreen extends StatefulWidget {
  final String password;
  final bool decoy;

  const VaultNotesScreen({
    super.key,
    required this.password,
    this.decoy = false,
  });

  @override
  State<VaultNotesScreen> createState() => _VaultNotesScreenState();
}

class _VaultNotesScreenState extends State<VaultNotesScreen> {
  late final VaultStorage _storage;
  late final String _salt;

  List<_VaultNote> notes = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _storage = VaultStorage(decoy: widget.decoy);
    _salt = VaultCrypto.getOrCreateSalt(Hive.box('settings'));
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final loaded = <_VaultNote>[];
    try {
      final dir = await _storage.notesDir();
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.note.enc')) continue;
        try {
          final plain = VaultCrypto.decryptBytes(
            await e.readAsBytes(),
            widget.password,
            _salt,
          );
          final map =
              jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
          final fileName = e.path.split('/').last;
          loaded.add(_VaultNote(
            id: fileName.substring(
                0, fileName.length - '.note.enc'.length),
            title: (map['title'] as String?) ?? '',
            body: (map['body'] as String?) ?? '',
            updatedAt: (map['updatedAt'] as int?) ?? 0,
          ));
        } catch (_) {
          // Skip corrupt notes.
        }
      }
    } catch (_) {}
    loaded.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (mounted) {
      setState(() {
        notes = loaded;
        loading = false;
      });
    }
  }

  Future<void> _saveNote(_VaultNote note) async {
    final dir = await _storage.notesDir();
    final jsonStr = jsonEncode({
      'title': note.title,
      'body': note.body,
      'updatedAt': note.updatedAt,
    });
    final enc = VaultCrypto.encryptBytes(
      Uint8List.fromList(utf8.encode(jsonStr)),
      widget.password,
      _salt,
    );
    await File('${dir.path}/${note.fileName}')
        .writeAsBytes(enc, flush: true);
  }

  void _openEditor({_VaultNote? note}) {
    final target = note ??
        _VaultNote(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: '',
          body: '',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _VaultNoteEditor(
          note: target,
          isNew: note == null,
          onSave: _saveNote,
        ),
      ),
    ).then((saved) {
      if (saved == true) _load();
    });
  }

  void _deleteNote(_VaultNote note) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text("Delete note?",
            style: TextStyle(color: VaultTheme.textPrimary)),
        content: const Text(
          "This note will be permanently deleted.",
          style: TextStyle(color: VaultTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                final dir = await _storage.notesDir();
                await File('${dir.path}/${note.fileName}')
                    .delete();
              } catch (_) {}
              _load();
            },
            child: const Text("Delete",
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
      ),
    );
  }

  String _formatDate(int ms) {
    if (ms == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
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
          "Vault Notes",
          style: TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : notes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.note_outlined,
                          size: 48,
                          color: VaultTheme.textSecondary),
                      SizedBox(height: 12),
                      Text(
                        "No vault notes yet",
                        style: TextStyle(
                            color: VaultTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Tap + to write an encrypted note",
                        style: TextStyle(
                            color: VaultTheme.textSecondary),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: notes.length,
                  itemBuilder: (_, i) {
                    final n = notes[i];
                    final title = n.title.trim().isEmpty
                        ? "Untitled"
                        : n.title.trim();
                    return Container(
                      margin:
                          const EdgeInsets.only(bottom: 10),
                      decoration:
                          VaultTheme.cardDecoration(),
                      child: ListTile(
                        leading: const Icon(
                            Icons.note_outlined,
                            color: VaultTheme.accent),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: VaultTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          n.body.trim().isEmpty
                              ? _formatDate(n.updatedAt)
                              : '${n.body.trim().split('\n').first}\n${_formatDate(n.updatedAt)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: VaultTheme.textSecondary,
                              fontSize: 13),
                        ),
                        isThreeLine:
                            n.body.trim().isNotEmpty,
                        trailing: IconButton(
                          icon: const Icon(
                              Icons.delete_outline,
                              color: VaultTheme.textSecondary),
                          onPressed: () => _deleteNote(n),
                        ),
                        onTap: () => _openEditor(note: n),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: VaultTheme.accent,
        foregroundColor: Colors.white,
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Simple editor for one vault note. Saves back through [onSave].
class _VaultNoteEditor extends StatefulWidget {
  final _VaultNote note;
  final bool isNew;
  final Future<void> Function(_VaultNote note) onSave;

  const _VaultNoteEditor({
    required this.note,
    required this.isNew,
    required this.onSave,
  });

  @override
  State<_VaultNoteEditor> createState() => _VaultNoteEditorState();
}

class _VaultNoteEditorState extends State<_VaultNoteEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl =
        TextEditingController(text: widget.note.title);
    _bodyCtrl = TextEditingController(text: widget.note.body);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty && body.isEmpty) {
      // Nothing to keep.
      if (mounted) Navigator.pop(context, false);
      return;
    }
    setState(() => _saving = true);
    try {
      widget.note.title = _titleCtrl.text;
      widget.note.body = _bodyCtrl.text;
      widget.note.updatedAt =
          DateTime.now().millisecondsSinceEpoch;
      await widget.onSave(widget.note);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save note: $e")),
        );
      }
    }
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
        title: Text(
          widget.isNew ? "New Note" : "Edit Note",
          style: const TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child:
                    CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.check,
                  color: VaultTheme.accent),
              tooltip: "Save",
              onPressed: _save,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _titleCtrl,
              style: const TextStyle(
                color: VaultTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              decoration: VaultTheme.inputDecoration("Title"),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _bodyCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                    color: VaultTheme.textPrimary,
                    fontSize: 16),
                decoration: VaultTheme.inputDecoration(
                        "Write something private...")
                    .copyWith(
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
