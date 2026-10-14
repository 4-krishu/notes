import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'album_screen.dart';

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
  List<String> albums = [];
  Map<String, int> itemCounts = {};

  static const String _albumsKey = 'vault_albums';

  @override
  void initState() {
    super.initState();
    settingsBox = Hive.box('settings');
    // Albums are persisted so they survive app restarts.
    albums = List<String>.from(
      settingsBox.get(
        _albumsKey,
        defaultValue: const ["Private", "Videos", "Favorites"],
      ),
    );
    _refreshCounts();
  }

  Future<Directory> _albumDir(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/vault/$name');
  }

  Future<void> _refreshCounts() async {
    final counts = <String, int>{};
    for (final name in albums) {
      final folder = await _albumDir(name);
      if (await folder.exists()) {
        final entries = await folder.list().toList();
        counts[name] = entries.whereType<File>().length;
      } else {
        counts[name] = 0;
      }
    }
    if (mounted) setState(() => itemCounts = counts);
  }

  void _addAlbum() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text("New Album"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: "Album name"),
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.dispose();
                Navigator.pop(context);
              },
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                controller.dispose();
                if (name.isEmpty) return;

                if (albums.contains(name)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("An album with this name already exists"),
                    ),
                  );
                  Navigator.pop(context);
                  return;
                }

                setState(() {
                  albums.add(name);
                });
                settingsBox.put(_albumsKey, albums);

                Navigator.pop(context);
                _refreshCounts();
              },
              child: const Text("Create"),
            ),
          ],
        );
      },
    );
  }

  void _openAlbum(String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          albumName: name,
          password: widget.password,
        ),
      ),
    ).then((_) => _refreshCounts());
  }

  Widget _buildEmpty() {
    return const Center(
      child: Text(
        "No Albums Yet\nTap + to create one",
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16),
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: albums.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 130,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemBuilder: (_, i) {
        final name = albums[i];
        final count = itemCounts[name] ?? 0;

        return GestureDetector(
          onTap: () => _openAlbum(name),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.pink.shade100,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.folder, size: 40, color: Colors.pink),
                const Spacer(),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  "$count ${count == 1 ? "item" : "items"}",
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
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
        title: const Text("Vault"),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_open),
            onPressed: () {
              Navigator.pop(context);
            },
          )
        ],
      ),
      body: albums.isEmpty ? _buildEmpty() : _buildGrid(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.pink,
        onPressed: _addAlbum,
        child: const Icon(Icons.add),
      ),
    );
  }
}
