import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../security/vault_crypto.dart';

/// One decrypted vault item. Bytes are decrypted on load; the file on disk
/// stays encrypted at all times.
class _VaultFile {
  final String path; // encrypted .enc file on disk
  final String ext; // original extension, e.g. ".jpg"
  final bool isVideo;
  final Uint8List bytes; // decrypted bytes (memory only)

  _VaultFile({
    required this.path,
    required this.ext,
    required this.isVideo,
    required this.bytes,
  });
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

  String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return '';
    return path.substring(dot).toLowerCase();
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Imports files: encrypts a copy into the vault, verifies the round-trip,
  /// and only then deletes the original so it no longer sits in the gallery.
  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.media,
    );

    if (result == null) return;

    final vaultPath = await _getVaultPath();
    var counter = 0;

    for (final picked in result.files) {
      if (picked.path == null) continue;
      final original = File(picked.path!);

      try {
        final ext = _extOf(picked.path!);
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
        if (!_bytesEqual(roundTrip, plain)) {
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
          // Filename format: <millis>_<n>.<ext>.enc
          final fileName = file.path.split('/').last;
          final withoutEnc =
              fileName.substring(0, fileName.length - '.enc'.length);
          final ext = _extOf(withoutEnc);
          loaded.add(_VaultFile(
            path: file.path,
            ext: ext,
            isVideo: _videoExts.contains(ext),
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
          title: const Text("Delete files?"),
          content: Text(
            "Delete ${selectedIndexes.length} file(s)? "
            "This cannot be undone.",
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
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openViewer(int index) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.pink.shade50,
      appBar: AppBar(
        backgroundColor: Colors.pink,
        title: Text(widget.albumName),
        actions: [
          if (selectionMode)
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: _selectAll,
            ),
          if (selectionMode)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteSelected,
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : media.isEmpty
              ? const Center(child: Text("No media"))
              : GridView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: media.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemBuilder: (_, i) {
                    final file = media[i];
                    final selected = selectedIndexes.contains(i);

                    return GestureDetector(
                      onTap: () {
                        if (selectionMode) {
                          _toggleSelection(i);
                        } else {
                          _openViewer(i);
                        }
                      },
                      onLongPress: () => _toggleSelection(i),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: file.isVideo
                                ? Container(
                                    color: Colors.black12,
                                    child: const Icon(Icons.video_file),
                                  )
                                : Image.memory(file.bytes,
                                    fit: BoxFit.cover),
                          ),
                          if (selected)
                            const Positioned(
                              top: 5,
                              right: 5,
                              child: Icon(Icons.check_circle,
                                  color: Colors.pink),
                            ),
                        ],
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.pink,
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
                            if (_videoController!.value.isPlaying) {
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
