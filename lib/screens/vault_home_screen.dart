import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../security/vault_crypto.dart';
import 'album_screen.dart';
import 'vault_theme.dart';

class VaultHomeScreen extends StatefulWidget {
  /// Vault password, kept in memory only. Used to encrypt/decrypt files.
  /// Never persisted.
  final String password;

  const VaultHomeScreen({super.key, required this.password});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  late Box settingsBox;
  late String _salt;

  /// In-memory password; updated after a successful password change.
  late String _password;

  List<String> albums = [];
  Map<String, int> itemCounts = {};
  Map<String, Uint8List> covers = {};
  bool loading = true;

  static const String _albumsKey = 'vault_albums';
  static const List<String> _imageExts = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
  ];

  @override
  void initState() {
    super.initState();
    _password = widget.password;
    settingsBox = Hive.box('settings');
    _salt = VaultCrypto.getOrCreateSalt(settingsBox);
    // Albums are persisted so they survive app restarts.
    albums = List<String>.from(
      settingsBox.get(
        _albumsKey,
        defaultValue: const ["Private", "Videos", "Favorites"],
      ),
    );
    _refresh();
  }

  Future<Directory> _albumDir(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/vault/$name');
  }

  Future<String> _vaultRoot() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/vault';
  }

  String _extOf(String fileName) {
    // Filename format: <millis>_<n>.<ext>.enc
    var name = fileName;
    if (name.endsWith('.enc')) {
      name = name.substring(0, name.length - '.enc'.length);
    }
    final dot = name.lastIndexOf('.');
    if (dot == -1) return '';
    return name.substring(dot).toLowerCase();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => loading = true);

    final counts = <String, int>{};
    final newCovers = <String, Uint8List>{};

    for (final name in albums) {
      final folder = await _albumDir(name);
      if (await folder.exists()) {
        final entries = await folder.list().toList();
        final encFiles = entries
            .whereType<File>()
            .where((f) => f.path.endsWith('.enc'))
            .toList();
        counts[name] = encFiles.length;

        // Cover: first image file, decrypted.
        for (final f in encFiles) {
          if (_imageExts.contains(_extOf(f.path.split('/').last))) {
            try {
              newCovers[name] = VaultCrypto.decryptBytes(
                await f.readAsBytes(),
                _password,
                _salt,
              );
            } catch (_) {
              // Skip unreadable files.
            }
            break;
          }
        }
      } else {
        counts[name] = 0;
      }
    }

    if (mounted) {
      setState(() {
        itemCounts = counts;
        covers = newCovers;
        loading = false;
      });
    }
  }

  void _saveAlbums() => settingsBox.put(_albumsKey, albums);

  // ------------------------------------------------------------------
  // Albums: create / rename / delete
  // ------------------------------------------------------------------

  void _addAlbum() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text(
          "New Album",
          style: TextStyle(color: VaultTheme.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: VaultTheme.textPrimary),
          decoration: VaultTheme.inputDecoration("Album name"),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              Navigator.pop(dialogContext);
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              controller.dispose();
              Navigator.pop(dialogContext);
              if (name.isEmpty) return;
              if (name.contains('/')) {
                _snack("Album name can't contain /");
                return;
              }
              if (albums.contains(name)) {
                _snack("An album with this name already exists");
                return;
              }
              setState(() => albums.add(name));
              _saveAlbums();
              _refresh();
            },
            child: const Text(
              "Create",
              style: TextStyle(color: VaultTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _renameAlbum(String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text(
          "Rename Album",
          style: TextStyle(color: VaultTheme.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: VaultTheme.textPrimary),
          decoration: VaultTheme.inputDecoration("Album name"),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              Navigator.pop(dialogContext);
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              controller.dispose();
              Navigator.pop(dialogContext);
              if (name.isEmpty || name == oldName) return;
              if (name.contains('/')) {
                _snack("Album name can't contain /");
                return;
              }
              if (albums.contains(name)) {
                _snack("An album with this name already exists");
                return;
              }
              try {
                final oldDir = await _albumDir(oldName);
                if (await oldDir.exists()) {
                  final root = await _vaultRoot();
                  await oldDir.rename('$root/$name');
                }
                final i = albums.indexOf(oldName);
                setState(() => albums[i] = name);
                _saveAlbums();
                _refresh();
              } catch (e) {
                _snack("Couldn't rename album: $e");
              }
            },
            child: const Text(
              "Rename",
              style: TextStyle(color: VaultTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  void _deleteAlbum(String name) {
    final count = itemCounts[name] ?? 0;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text(
          "Delete Album?",
          style: TextStyle(color: VaultTheme.textPrimary),
        ),
        content: Text(
          count == 0
              ? 'Delete "$name"?'
              : 'Delete "$name" and its $count file(s)? This cannot be undone.',
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
                final dir = await _albumDir(name);
                if (await dir.exists()) {
                  await dir.delete(recursive: true);
                }
              } catch (_) {
                // Best effort; still remove from the list.
              }
              setState(() => albums.remove(name));
              _saveAlbums();
              _refresh();
            },
            child: const Text(
              "Delete",
              style: TextStyle(color: VaultTheme.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _albumOptions(String name) {
    showModalBottomSheet(
      context: context,
      backgroundColor: VaultTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline,
                  color: VaultTheme.textPrimary),
              title: const Text("Rename album",
                  style: TextStyle(color: VaultTheme.textPrimary)),
              onTap: () {
                Navigator.pop(context);
                _renameAlbum(name);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: VaultTheme.danger),
              title: const Text("Delete album",
                  style: TextStyle(color: VaultTheme.danger)),
              onTap: () {
                Navigator.pop(context);
                _deleteAlbum(name);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Change password
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

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text(
          "Change Password",
          style: TextStyle(color: VaultTheme.textPrimary),
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

              // Block the UI while re-encrypting every file.
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );

              try {
                final root = await _vaultRoot();
                await VaultCrypto.changePassword(
                  vaultRoot: root,
                  oldPassword: current,
                  newPassword: newPw,
                  salt: _salt,
                );
                // Only now is it safe to replace the stored hash.
                settingsBox.put(
                  VaultCrypto.passwordHashKey,
                  VaultCrypto.hashPassword(newPw, _salt),
                );
                setState(() => _password = newPw);
                disposeAll();
                if (mounted) {
                  Navigator.pop(context); // loading
                  Navigator.pop(dialogContext); // dialog
                  _snack("Password changed");
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context); // loading
                  _snack(
                      "Couldn't change password. Wrong current password?");
                }
              }
            },
            child: const Text(
              "Change",
              style: TextStyle(color: VaultTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openAlbum(String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          albumName: name,
          password: _password,
        ),
      ),
    ).then((_) => _refresh());
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: VaultTheme.surface,
              borderRadius: BorderRadius.circular(32),
            ),
            child: const Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: VaultTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "No albums yet",
            style: TextStyle(
              color: VaultTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "Tap + to create your first album",
            style: TextStyle(color: VaultTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: albums.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 190,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemBuilder: (_, i) {
        final name = albums[i];
        final count = itemCounts[name] ?? 0;
        final cover = covers[name];

        return GestureDetector(
          onTap: () => _openAlbum(name),
          onLongPress: () => _albumOptions(name),
          child: Container(
            decoration: VaultTheme.cardDecoration(),
            child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(VaultTheme.cardRadius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cover != null)
                    Image.memory(cover, fit: BoxFit.cover)
                  else
                    Container(
                      color: VaultTheme.surfaceLight,
                      child: const Icon(
                        Icons.folder_outlined,
                        size: 48,
                        color: VaultTheme.textSecondary,
                      ),
                    ),
                  // Bottom gradient with name + count.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(
                          12, 24, 12, 12),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black87,
                          ],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "$count ${count == 1 ? "item" : "items"}",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
        title: const Text(
          "Vault",
          style: TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                color: VaultTheme.textPrimary),
            color: VaultTheme.surface,
            onSelected: (v) {
              if (v == 'change_pw') _changePassword();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'change_pw',
                child: Text(
                  "Change password",
                  style:
                      TextStyle(color: VaultTheme.textPrimary),
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.lock,
                color: VaultTheme.textPrimary),
            tooltip: "Lock vault",
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : albums.isEmpty
              ? _buildEmpty()
              : _buildGrid(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: VaultTheme.accent,
        foregroundColor: Colors.white,
        onPressed: _addAlbum,
        child: const Icon(Icons.add),
      ),
    );
  }
}
