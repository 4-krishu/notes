import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../security/vault_storage.dart';
import '../security/vault_trash.dart';
import 'vault_theme.dart';

/// Trash bin: deleted vault files rest here (still encrypted) for 30 days
/// before permanent deletion. Items can be restored or deleted forever.
class VaultTrashScreen extends StatefulWidget {
  final VaultStorage storage;

  const VaultTrashScreen({super.key, required this.storage});

  @override
  State<VaultTrashScreen> createState() => _VaultTrashScreenState();
}

class _VaultTrashScreenState extends State<VaultTrashScreen> {
  List<TrashItem> items = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final trashDir = await widget.storage.trashDir();
      final loaded = await VaultTrash.listItems(trashDir);
      if (mounted) {
        setState(() {
          items = loaded;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _restore(TrashItem item) async {
    try {
      final trashDir = await widget.storage.trashDir();
      await VaultTrash.restoreItem(
        item: item,
        trashDir: trashDir,
        albumDirFor: (album) async {
          if (album == '.notes') return widget.storage.notesDir();
          return widget.storage.albumDir(album);
        },
      );
      // If the album was deleted after the file was trashed, the restored
      // file would land in a folder the home screen never lists. Re-add
      // the album name so it becomes visible again.
      if (item.album != '.notes') {
        final box = Hive.box('settings');
        final key = widget.storage.albumsKey;
        final albums = List<String>.from(
          box.get(key, defaultValue: const <String>[]),
        );
        if (!albums.contains(item.album)) {
          albums.add(item.album);
          box.put(key, albums);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Restored to ${item.album}")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't restore: $e")),
        );
      }
    }
    _load();
  }

  void _deleteForever(TrashItem item) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text("Delete forever?",
            style: TextStyle(color: VaultTheme.textPrimary)),
        content: const Text(
          "This file will be permanently deleted. "
          "This cannot be undone.",
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
                final trashDir = await widget.storage.trashDir();
                await VaultTrash.deletePermanently(item, trashDir);
              } catch (_) {}
              _load();
            },
            child: const Text("Delete forever",
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
      ),
    );
  }

  void _emptyTrash() {
    if (items.isEmpty) return;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text("Empty trash?",
            style: TextStyle(color: VaultTheme.textPrimary)),
        content: Text(
          "Permanently delete all ${items.length} item(s)? "
          "This cannot be undone.",
          style: const TextStyle(color: VaultTheme.textSecondary),
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
                final trashDir = await widget.storage.trashDir();
                for (final it in List.of(items)) {
                  await VaultTrash.deletePermanently(it, trashDir);
                }
              } catch (_) {}
              _load();
            },
            child: const Text("Empty trash",
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
          "Trash Bin",
          style: TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined,
                  color: VaultTheme.danger),
              tooltip: "Empty trash",
              onPressed: _emptyTrash,
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 48,
                          color: VaultTheme.textSecondary),
                      SizedBox(height: 12),
                      Text(
                        "Trash is empty",
                        style: TextStyle(
                            color: VaultTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Deleted files stay here for 30 days",
                        style: TextStyle(
                            color: VaultTheme.textSecondary),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(
                          16, 8, 16, 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration:
                          VaultTheme.cardDecoration(),
                      child: const Text(
                        "Items are permanently deleted 30 days after "
                        "being trashed.",
                        style: TextStyle(
                            color: VaultTheme.textSecondary,
                            fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final item = items[i];
                          return Container(
                            margin: const EdgeInsets.only(
                                bottom: 8),
                            decoration:
                                VaultTheme.cardDecoration(),
                            child: ListTile(
                              leading: Icon(
                                item.isNote
                                    ? Icons.note_outlined
                                    : Icons
                                        .insert_drive_file_outlined,
                                color: VaultTheme.accent,
                              ),
                              title: Text(
                                item.displayName,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: VaultTheme
                                        .textPrimary),
                              ),
                              subtitle: Text(
                                "${item.album} · ${_formatSize(item.size)} · "
                                "${item.daysLeft}d left",
                                style: const TextStyle(
                                    color: VaultTheme
                                        .textSecondary,
                                    fontSize: 12),
                              ),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(
                                    Icons.more_vert,
                                    color: VaultTheme
                                        .textSecondary),
                                color: VaultTheme.surface,
                                onSelected: (v) {
                                  if (v == 'restore') {
                                    _restore(item);
                                  } else if (v ==
                                      'delete') {
                                    _deleteForever(item);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'restore',
                                    child: Text("Restore",
                                        style: TextStyle(
                                            color: VaultTheme
                                                .textPrimary)),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(
                                        "Delete forever",
                                        style: TextStyle(
                                            color: VaultTheme
                                                .danger)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
