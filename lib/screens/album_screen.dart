import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../security/vault_crypto.dart';
import 'vault_theme.dart';

/// One decrypted vault item. Bytes are decrypted on load; the file on disk
/// stays encrypted at all times.
class _VaultFile {
  final String path; // encrypted .enc file on disk
  final String name; // original filename without the .enc suffix
  final String ext; // original extension, e.g. ".jpg"
  final bool isVideo;
  final bool isImage;
  final Uint8List bytes; // decrypted bytes (memory only)

  _VaultFile({
    required this.path,
    required this.name,
    required this.ext,
    required this.isVideo,
    required this.isImage,
    required this.bytes,
  });

  bool get isDocument => !isVideo && !isImage;
}

class AlbumScreen extends StatefulWidget {
  final String albumName;

  /// Vault password, kept in memory only. Used to encrypt/decrypt files.
  final String password;

  const AlbumScreen({
    super.key,
    required this.albumName,
    required this.password,
  });

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<_VaultFile> media = [];
  Set<int> selectedIndexes = {};

  bool selectionMode = false;
  bool loading = true;

  late final String _salt;

  static const List<String> _videoExts = [
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.webm',
  ];

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
    _salt = VaultCrypto.getOrCreateSalt(Hive.box('settings'));
    _loadMedia();
  }

  Future<String> _getVaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/vault/${widget.albumName}');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder.path;
  }

  /// "1730000000000_0.jpg.enc" -> ".jpg"
  String _extOf(String fileName) {
    var name = fileName;
    if (name.endsWith('.enc')) {
      name = name.substring(0, name.length - '.enc'.length);
    }
    final dot = name.lastIndexOf('.');
    if (dot == -1) return '';
    return name.substring(dot).toLowerCase();
  }

  /// Imports files: encrypts a copy into the vault, verifies the round-trip,
  /// and only then deletes the original so it no longer sits in the gallery.
  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result == null) return;

    final vaultPath = await _getVaultPath();
    var counter = 0;

    for (final picked in result.files) {
      if (picked.path == null) continue;
      final original = File(picked.path!);

      try {
        final ext = _extOf(picked.name);
        final name =
            '${DateTime.now().millisecondsSinceEpoch}_${counter++}$ext.enc';
        final destPath = '$vaultPath/$name';

        final plain = await original.readAsBytes();
        final encrypted =
            VaultCrypto.encryptBytes(plain, widget.password, _salt);
        await File(destPath).writeAsBytes(encrypted, flush: true);

        // Verify the encrypted file decrypts back to identical bytes
        // BEFORE deleting the original. Never delete first.
        final roundTrip = VaultCrypto.decryptBytes(
          await File(destPath).readAsBytes(),
          widget.password,
          _salt,
        );
        if (!VaultCrypto.bytesEqual(roundTrip, plain)) {
          throw const FormatException('Encryption verification failed');
        }

        await original.delete();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not import a file: $e')),
          );
        }
      }
    }

    await _loadMedia();
  }

  Future<void> _loadMedia() async {
    if (mounted) setState(() => loading = true);
    try {
      final vaultPath = await _getVaultPath();
      final dir = Directory(vaultPath);
      final entries = await dir.list().toList();
      final files = entries
          .whereType<File>()
          .where((f) => f.path.endsWith('.enc'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // newest first

      final loaded = <_VaultFile>[];
      for (final file in files) {
        try {
          final data = await file.readAsBytes();
          final bytes =
              VaultCrypto.decryptBytes(data, widget.password, _salt);
          final fileName = file.path.split('/').last;
          final name = fileName.substring(
              0, fileName.length - '.enc'.length);
          final ext = _extOf(fileName);
          loaded.add(_VaultFile(
            path: file.path,
            name: name,
            ext: ext,
            isVideo: _videoExts.contains(ext),
            isImage: _imageExts.contains(ext),
            bytes: bytes,
          ));
        } catch (_) {
          // Skip files that fail to decrypt (corrupt or foreign files).
        }
      }

      if (mounted) {
        setState(() {
          media = loaded;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  // ------------------------------------------------------------------
  // Selection: delete / move
  // ------------------------------------------------------------------

  void _toggleSelection(int index) {
    setState(() {
      selectionMode = true;

      if (selectedIndexes.contains(index)) {
        selectedIndexes.remove(index);
      } else {
        selectedIndexes.add(index);
      }

      if (selectedIndexes.isEmpty) {
        selectionMode = false;
      }
    });
  }

  void _selectAll() {
    setState(() {
      selectedIndexes = Set.from(
        List.generate(media.length, (i) => i),
      );
      selectionMode = true;
    });
  }

  void _deleteSelected() {
    if (selectedIndexes.isEmpty) return;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: VaultTheme.surface,
          title: const Text(
            "Delete files?",
            style: TextStyle(color: VaultTheme.textPrimary),
          ),
          content: Text(
            "Delete ${selectedIndexes.length} file(s)? "
            "This cannot be undone.",
            style:
                const TextStyle(color: VaultTheme.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                final targets =
                    selectedIndexes.map((i) => media[i]).toList();
                for (final item in targets) {
                  try {
                    await File(item.path).delete();
                  } catch (_) {
                    // Already gone; continue with the rest.
                  }
                }
                if (mounted) {
                  setState(() {
                    media.removeWhere((m) => targets.contains(m));
                    selectedIndexes.clear();
                    selectionMode = false;
                  });
                }
              },
              child: const Text(
                "Delete",
                style: TextStyle(color: VaultTheme.danger),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Moves the selected files to another album. No re-encryption needed:
  /// encryption is password-based, not album-based.
  void _moveSelected() {
    if (selectedIndexes.isEmpty) return;

    final allAlbums = List<String>.from(
      Hive.box('settings').get(
        'vault_albums',
        defaultValue: const <String>[],
      ),
    );
    final targets =
        allAlbums.where((a) => a != widget.albumName).toList();

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other albums to move to")),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: VaultTheme.surface,
          title: const Text(
            "Move to album",
            style: TextStyle(color: VaultTheme.textPrimary),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: targets.length,
              itemBuilder: (_, i) {
                return ListTile(
                  leading: const Icon(Icons.folder_outlined,
                      color: VaultTheme.accent),
                  title: Text(
                    targets[i],
                    style: const TextStyle(
                        color: VaultTheme.textPrimary),
                  ),
                  onTap: () async {
                    Navigator.pop(dialogContext);
                    final docs =
                        await getApplicationDocumentsDirectory();
                    final destDir = Directory(
                        '${docs.path}/vault/${targets[i]}');
                    if (!await destDir.exists()) {
                      await destDir.create(recursive: true);
                    }
                    final items = selectedIndexes
                        .map((idx) => media[idx])
                        .toList();
                    for (final item in items) {
                      try {
                        final fileName =
                            item.path.split('/').last;
                        await File(item.path).rename(
                            '${destDir.path}/$fileName');
                      } catch (_) {
                        // Continue with the rest.
                      }
                    }
                    if (mounted) {
                      setState(() {
                        media.removeWhere(
                            (m) => items.contains(m));
                        selectedIndexes.clear();
                        selectionMode = false;
                      });
                    }
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              "Moved ${items.length} file(s) to ${targets[i]}"),
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------
  // Opening files
  // ------------------------------------------------------------------

  void _openItem(int index) {
    final item = media[index];
    if (item.isDocument) {
      _openDocument(item);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FullScreenViewer(
            media: media,
            initialIndex: index,
          ),
        ),
      );
    }
  }

  /// Decrypts a document to a temp file and opens it with an external app.
  Future<void> _openDocument(_VaultFile item) async {
    try {
      final tmp = await getTemporaryDirectory();
      final path =
          '${tmp.path}/vault_doc_${DateTime.now().millisecondsSinceEpoch}${item.ext}';
      await File(path).writeAsBytes(item.bytes, flush: true);
      await OpenFilex.open(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't open file: $e")),
        );
      }
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Widget _buildTile(_VaultFile file, bool selected) {
    Widget content;
    if (file.isVideo) {
      content = Container(
        color: VaultTheme.surfaceLight,
        child: const Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.videocam_outlined,
                size: 36, color: VaultTheme.textSecondary),
            Positioned(
              bottom: 6,
              right: 6,
              child: Icon(Icons.play_circle_filled,
                  size: 20, color: VaultTheme.accent),
            ),
          ],
        ),
      );
    } else if (file.isImage) {
      content = Image.memory(file.bytes, fit: BoxFit.cover);
    } else {
      content = Container(
        color: VaultTheme.surfaceLight,
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.description_outlined,
                size: 32, color: VaultTheme.accent),
            const SizedBox(height: 6),
            Text(
              file.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: VaultTheme.textSecondary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: selected
            ? Border.all(color: VaultTheme.accent, width: 2.5)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (selected)
              Container(
                color: VaultTheme.accent.withOpacity(0.25),
                child: const Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.check_circle,
                        color: VaultTheme.accent),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VaultTheme.background,
      appBar: AppBar(
        backgroundColor: VaultTheme.background,
        elevation: 0,
        title: Text(
          selectionMode
              ? "${selectedIndexes.length} selected"
              : widget.albumName,
          style: const TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme:
            const IconThemeData(color: VaultTheme.textPrimary),
        actions: [
          if (selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "Select all",
              onPressed: _selectAll,
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_outlined),
              tooltip: "Move to album",
              onPressed: _moveSelected,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Delete",
              onPressed: _deleteSelected,
            ),
          ],
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : media.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: VaultTheme.surface,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: const Icon(
                          Icons.photo_library_outlined,
                          size: 40,
                          color: VaultTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        "Nothing here yet",
                        style: TextStyle(
                          color: VaultTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Tap + to import photos, videos or files",
                        style: TextStyle(
                            color: VaultTheme.textSecondary),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: media.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (_, i) {
                    final file = media[i];
                    final selected =
                        selectedIndexes.contains(i);

                    return GestureDetector(
                      onTap: () {
                        if (selectionMode) {
                          _toggleSelection(i);
                        } else {
                          _openItem(i);
                        }
                      },
                      onLongPress: () => _toggleSelection(i),
                      child: _buildTile(file, selected),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: VaultTheme.accent,
        foregroundColor: Colors.white,
        onPressed: _pickMedia,
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Full-screen viewer: images from memory, videos decrypted to a temporary
/// file and played with video_player. The temp file is deleted on close.
class FullScreenViewer extends StatefulWidget {
  final List<_VaultFile> media;
  final int initialIndex;

  const FullScreenViewer({
    super.key,
    required this.media,
    required this.initialIndex,
  });

  @override
  State<FullScreenViewer> createState() => _FullScreenViewerState();
}

class _FullScreenViewerState extends State<FullScreenViewer> {
  late PageController controller;
  VideoPlayerController? _videoController;
  String? _tempVideoPath;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    controller = PageController(initialPage: _current);
    _maybeInitVideo(_current);
  }

  Future<void> _maybeInitVideo(int index) async {
    await _disposeVideo();

    final item = widget.media[index];
    if (!item.isVideo) return;

    final tmp = await getTemporaryDirectory();
    final ext = item.ext.isEmpty ? '.mp4' : item.ext;
    final path =
        '${tmp.path}/vault_play_${DateTime.now().millisecondsSinceEpoch}$ext';
    await File(path).writeAsBytes(item.bytes, flush: true);
    _tempVideoPath = path;

    _videoController = VideoPlayerController.file(File(path));
    await _videoController!.initialize();
    if (mounted) setState(() {});
    await _videoController!.play();
  }

  Future<void> _disposeVideo() async {
    await _videoController?.dispose();
    _videoController = null;
    if (_tempVideoPath != null) {
      try {
        await File(_tempVideoPath!).delete();
      } catch (_) {
        // Best effort cleanup.
      }
      _tempVideoPath = null;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    _disposeVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: controller,
        itemCount: widget.media.length,
        onPageChanged: (i) {
          setState(() => _current = i);
          _maybeInitVideo(i);
        },
        itemBuilder: (_, i) {
          final item = widget.media[i];

          if (item.isDocument) {
            return const Center(
              child: Text(
                "Preview not available",
                style: TextStyle(color: Colors.white70),
              ),
            );
          }

          if (!item.isVideo) {
            return Center(child: Image.memory(item.bytes));
          }

          if (_videoController != null &&
              _videoController!.value.isInitialized &&
              i == _current) {
            return Center(
              child: AspectRatio(
                aspectRatio: _videoController!.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    VideoPlayer(_videoController!),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: IconButton(
                        icon: Icon(
                          _videoController!.value.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                          size: 48,
                        ),
                        onPressed: () {
                          setState(() {
                            if (_videoController!
                                .value.isPlaying) {
                              _videoController!.pause();
                            } else {
                              _videoController!.play();
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return const Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}
