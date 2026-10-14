import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../security/vault_crypto.dart';
import '../security/vault_prefs.dart';
import '../security/vault_storage.dart';
import 'album_screen.dart';
import 'vault_lock_screen.dart';
import 'vault_settings_screen.dart';
import 'vault_theme.dart';

class VaultHomeScreen extends StatefulWidget {
  /// Vault password, kept in memory only. Used to encrypt/decrypt files.
  /// Never persisted.
  final String password;

  /// When true, this screen shows the decoy vault (separate directory,
  /// separate album list) instead of the real one.
  final bool decoy;

  const VaultHomeScreen({
    super.key,
    required this.password,
    this.decoy = false,
  });

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen>
    with WidgetsBindingObserver {
  late Box settingsBox;
  late String _salt;
  late VaultStorage _storage;

  /// In-memory password; updated after a successful password change.
  late String _password;

  List<String> albums = [];
  Map<String, int> itemCounts = {};
  Map<String, Uint8List> covers = {};
  bool loading = true;

  // --- auto-lock ---
  int? _backgroundedAtMs;

  // --- panic gesture (shake to lock) ---
  StreamSubscription<AccelerometerEvent>? _shakeSub;
  final List<int> _spikeTimes = [];
  int _lastShakeTriggerMs = 0;

  List<String> get _defaultAlbums => widget.decoy
      ? const ["Photos", "Videos"]
      : const ["Private", "Videos", "Favorites"];

  @override
  void initState() {
    super.initState();
    _password = widget.password;
    _storage = VaultStorage(decoy: widget.decoy);
    settingsBox = Hive.box('settings');
    _salt = VaultCrypto.getOrCreateSalt(settingsBox);
    // Albums are persisted so they survive app restarts.
    albums = List<String>.from(
      settingsBox.get(
        _storage.albumsKey,
        defaultValue: _defaultAlbums,
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    _subscribeShake();
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shakeSub?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Auto-lock: if the app was in the background longer than the
  // configured timeout, require re-authentication on return.
  // ------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAtMs = DateTime.now().millisecondsSinceEpoch;
    } else if (state == AppLifecycleState.resumed) {
      final timeout = VaultPrefs.getInt(VaultPrefs.autoLockSeconds);
      final bgAt = _backgroundedAtMs;
      _backgroundedAtMs = null;
      if (timeout > 0 && bgAt != null) {
        final awaySecs =
            (DateTime.now().millisecondsSinceEpoch - bgAt) ~/ 1000;
        if (awaySecs >= timeout) _relock();
      }
    }
  }

  void _relock() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const VaultLockScreen()),
      (route) => route.isFirst,
    );
  }

  // ------------------------------------------------------------------
  // Panic gesture: two firm shakes within ~1 second instantly lock.
  // ------------------------------------------------------------------

  void _subscribeShake() {
    _shakeSub = accelerometerEventStream().listen(
      (event) {
        if (!VaultPrefs.getBool(VaultPrefs.shakeLockEnabled)) return;
        final g = sqrt(event.x * event.x +
                event.y * event.y +
                event.z * event.z) /
            9.81;
        if (g < 2.6) return; // not a firm shake
        final now = DateTime.now().millisecondsSinceEpoch;
        _spikeTimes.add(now);
        _spikeTimes.removeWhere((t) => now - t > 1000);
        if (_spikeTimes.length >= 2 &&
            now - _lastShakeTriggerMs > 3000) {
          _lastShakeTriggerMs = now;
          _spikeTimes.clear();
          _panicLock();
        }
      },
      onError: (_) {},
    );
  }

  void _panicLock() {
    if (!mounted) return;
    // Pop everything above the notes screen: the vault just vanishes.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<String> _vaultRoot() => _storage.rootPath();

  Future<void> _refresh() async {
    if (mounted) setState(() => loading = true);

    final counts = <String, int>{};
    final newCovers = <String, Uint8List>{};

    for (final name in albums) {
      final folder = await _storage.albumDir(name);
      if (await folder.exists()) {
        final entries = await folder.list().toList();
        final files = entries.whereType<File>().toList();
        // Count real items only: thumbnails (*.thumb.enc) are not items.
        final itemFiles = files
            .where((f) =>
                f.path.endsWith('.enc') &&
                !f.path.endsWith('.thumb.enc'))
            .toList();
        counts[name] = itemFiles.length;

        // Cover: first available thumbnail (small, cheap to decrypt).
        final thumbs = files
            .where((f) => f.path.endsWith('.thumb.enc'))
            .toList();
        if (thumbs.isNotEmpty) {
          try {
            newCovers[name] = VaultCrypto.decryptBytes(
              await thumbs.first.readAsBytes(),
              _password,
              _salt,
            );
          } catch (_) {
            // Skip unreadable files.
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

  void _saveAlbums() => settingsBox.put(_storage.albumsKey, albums);

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
                final oldDir = await _storage.albumDir(oldName);
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
                final dir = await _storage.albumDir(name);
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
  // Navigation
  // ------------------------------------------------------------------

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VaultSettingsScreen(
          password: _password,
          decoy: widget.decoy,
          onPasswordChanged: (np) => setState(() => _password = np),
        ),
      ),
    ).then((_) => _refresh());
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
          decoy: widget.decoy,
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
        // In decoy mode a small dot sits next to the title: subtle enough
        // that only the owner knows what it means.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Vault",
              style: TextStyle(
                color: VaultTheme.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (widget.decoy) ...[
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: VaultTheme.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert,
                color: VaultTheme.textPrimary),
            color: VaultTheme.surface,
            onSelected: (v) {
              if (v == 'settings') _openSettings();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'settings',
                child: Text(
                  "Settings",
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
