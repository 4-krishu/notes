import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../security/vault_crypto.dart';
import '../security/vault_prefs.dart';
import '../security/vault_storage.dart';
import '../security/vault_trash.dart';
import 'album_screen.dart';
import 'vault_lock_screen.dart';
import 'vault_notes_screen.dart';
import 'vault_settings_screen.dart';
import 'vault_theme.dart';
import 'vault_trash_screen.dart';

class _SearchHit {
  final String album;
  final String fileName;
  _SearchHit(this.album, this.fileName);
}

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

  // --- search ---
  final TextEditingController _searchController =
      TextEditingController();
  String _query = '';
  List<_SearchHit> _searchHits = [];
  bool _searching = false;

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
    _searchController.addListener(_onSearchChanged);
    _subscribeShake();
    // Clean up plaintext temp copies left behind by document/video viewing
    // (e.g. after an app kill). Runs once per vault open, fire and forget.
    _sweepTempFiles();
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
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

  /// Deletes stale decrypted temp files (`vault_doc_*`, `vault_play_*`,
  /// `vault_vthumb_*`) left in the temp dir by earlier sessions. These are
  /// plaintext copies of vault content, so they must not linger.
  Future<void> _sweepTempFiles() async {
    try {
      final tmp = await getTemporaryDirectory();
      await for (final e in tmp.list()) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (name.startsWith('vault_doc_') ||
            name.startsWith('vault_play_') ||
            name.startsWith('vault_vthumb_')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => loading = true);

    // Trash auto-cleanup: permanently delete items older than 30 days.
    try {
      final removed = await VaultTrash.purgeExpired(
        await _storage.trashDir(),
      );
      if (removed > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Trash auto-emptied: $removed file(s) older than 30 days deleted",
            ),
          ),
        );
      }
    } catch (_) {}

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
  // Search across file names and album names, grouped by album.
  // ------------------------------------------------------------------

  void _onSearchChanged() {
    final q = _searchController.text.trim().toLowerCase();
    if (q == _query) return;
    _query = q;
    if (q.isEmpty) {
      setState(() {
        _searchHits = [];
        _searching = false;
      });
      return;
    }
    _runSearch(q);
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    final hits = <_SearchHit>[];
    for (final name in albums) {
      final dir = await _storage.albumDir(name);
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final fName = e.path.split('/').last;
        if (!fName.endsWith('.enc') ||
            fName.endsWith('.thumb.enc')) {
          continue;
        }
        final display =
            fName.substring(0, fName.length - '.enc'.length);
        if (display.toLowerCase().contains(q) ||
            name.toLowerCase().contains(q)) {
          hits.add(_SearchHit(name, display));
        }
      }
      if (_query != q) return; // a newer query superseded this one
    }
    if (!mounted || _query != q) return;
    setState(() {
      _searchHits = hits;
      _searching = false;
    });
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: VaultTheme.textPrimary),
        decoration: VaultTheme.inputDecoration("Search files")
            .copyWith(
          prefixIcon: const Icon(Icons.search,
              color: VaultTheme.textSecondary),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear,
                      color: VaultTheme.textSecondary),
                  onPressed: () => _searchController.clear(),
                ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchHits.isEmpty) {
      return Center(
        child: Text(
          'No results for "$_query"',
          style:
              const TextStyle(color: VaultTheme.textSecondary),
        ),
      );
    }
    final grouped = <String, List<_SearchHit>>{};
    for (final h in _searchHits) {
      grouped.putIfAbsent(h.album, () => []).add(h);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final album in grouped.keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(
              album,
              style: const TextStyle(
                color: VaultTheme.textSecondary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          for (final h in grouped[album]!)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: VaultTheme.cardDecoration(),
              child: ListTile(
                leading: const Icon(
                    Icons.insert_drive_file_outlined,
                    color: VaultTheme.accent),
                title: Text(
                  h.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: VaultTheme.textPrimary),
                ),
                onTap: () {
                  _searchController.clear();
                  _openAlbum(h.album);
                },
              ),
            ),
        ],
      ],
    );
  }

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

  /// Deleting an album moves its files to the trash (recoverable for
  /// 30 days) instead of permanently deleting them.
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
              : 'Delete "$name"? Its $count file(s) will be moved '
                  'to the trash.',
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
                  final trashDir = await _storage.trashDir();
                  final files = await dir
                      .list()
                      .where((e) =>
                          e is File &&
                          e.path.endsWith('.enc') &&
                          !e.path.endsWith('.thumb.enc'))
                      .toList();
                  await VaultTrash.moveFilesToTrash(
                    encPaths:
                        files.map((e) => e.path).toList(),
                    trashDir: trashDir,
                    albumName: name,
                  );
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

  void _openTrash() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VaultTrashScreen(storage: _storage),
      ),
    ).then((_) => _refresh());
  }

  void _openNotes() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VaultNotesScreen(
          password: _password,
          decoy: widget.decoy,
        ),
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
    final searching = _query.isNotEmpty;

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
              if (v == 'settings') {
                _openSettings();
              } else if (v == 'trash') {
                _openTrash();
              } else if (v == 'notes') {
                _openNotes();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'notes',
                child: Text(
                  "Vault notes",
                  style:
                      TextStyle(color: VaultTheme.textPrimary),
                ),
              ),
              PopupMenuItem(
                value: 'trash',
                child: Text(
                  "Trash bin",
                  style:
                      TextStyle(color: VaultTheme.textPrimary),
                ),
              ),
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
          : Column(
              children: [
                _buildSearchBar(),
                Expanded(
                  child: searching
                      ? _buildSearchResults()
                      : albums.isEmpty
                          ? _buildEmpty()
                          : _buildGrid(),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: VaultTheme.accent,
        foregroundColor: Colors.white,
        onPressed: _addAlbum,
        child: const Icon(Icons.add),
      ),
    );
  }
}
