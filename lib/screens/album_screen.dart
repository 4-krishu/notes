import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../security/vault_crypto.dart';
import 'vault_theme.dart';

/// One vault item. The grid only ever holds the small thumbnail bytes;
/// the full file is decrypted on demand when opened. This keeps memory
/// bounded no matter how many photos the album holds.
class _VaultFile {
  final String path; // encrypted full file: <base>.enc
  final String name; // display name without the .enc suffix
  final String ext; // original extension, e.g. ".jpg"
  final bool isVideo;
  final bool isImage;
  Uint8List? thumbBytes; // decrypted thumbnail (null until loaded)

  _VaultFile({
    required this.path,
    required this.name,
    required this.ext,
    required this.isVideo,
    required this.isImage,
    this.thumbBytes,
  });

  bool get isDocument => !isVideo && !isImage;

  /// "<dir>/X.jpg.enc" -> "<dir>/X.jpg.thumb.enc"
  String get thumbPath =>
      '${path.substring(0, path.length - '.enc'.length)}.thumb.enc';
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

  /// newest | oldest | name
  String _sortMode = 'newest';

  late final String _salt;

  /// Files larger than this are skipped on import: encrypting them would
  /// need several times their size in RAM at once.
  static const int _maxImportBytes = 250 * 1024 * 1024;

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
    _sortMode = Hive.box('settings')
            .get('vault_sort', defaultValue: 'newest')
        as String;
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

  /// Builds a small JPEG thumbnail from full image bytes.
  /// Returns null if the bytes aren't a decodable image.
  Uint8List? _makeThumbnail(Uint8List plain) {
    try {
      final decoded = img.decodeImage(plain);
      if (decoded == null) return null;
      final thumb = img.copyResize(decoded, width: 400);
      return Uint8List.fromList(img.encodeJpg(thumb, quality: 70));
    } catch (_) {
      return null;
    }
  }

  /// Imports files: encrypts a copy into the vault (plus an encrypted
  /// thumbnail for images), verifies the round-trip, and only then deletes
  /// the original so it no longer sits in the gallery.
  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result == null) return;
    final picked =
        result.files.where((f) => f.path != null).toList();
    if (picked.isEmpty) return;

    final vaultPath = await _getVaultPath();

    // Progress dialog: importing hundreds of files takes a while and
    // the app must not look frozen.
    int done = 0;
    int skippedLarge = 0;
    StateSetter? updateDialog;
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            updateDialog = setDialogState;
            return AlertDialog(
              backgroundColor: VaultTheme.surface,
              content: Row(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      "Importing $done of ${picked.length}...",
                      style: const TextStyle(
                          color: VaultTheme.textPrimary),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    var counter = 0;
    for (final f in picked) {
      try {
        final original = File(f.path!);
        if (await original.length() > _maxImportBytes) {
          skippedLarge++;
          continue;
        }

        final ext = _extOf(f.name);
        final base =
            '${DateTime.now().millisecondsSinceEpoch}_${counter++}$ext';
        final destPath = '$vaultPath/$base.enc';

        final plain = await original.readAsBytes();

        // Thumbnail for images (stored encrypted alongside).
        if (_imageExts.contains(ext)) {
          final thumb = _makeThumbnail(plain);
          if (thumb != null) {
            final encThumb = VaultCrypto.encryptBytes(
                thumb, widget.password, _salt);
            await File('$vaultPath/$base.thumb.enc')
                .writeAsBytes(encThumb, flush: true);
          }
        }

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
      } catch (_) {
        // Skip broken files; the rest still import.
      } finally {
        done++;
        updateDialog?.call(() {});
      }
    }

    if (mounted) Navigator.pop(context); // close progress dialog
    await _loadMedia();
    if (skippedLarge > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "$skippedLarge file(s) skipped (over 250 MB)"),
        ),
      );
    }
  }

  Future<void> _loadMedia() async {
    if (mounted) setState(() => loading = true);
    try {
      final vaultPath = await _getVaultPath();
      final dir = Directory(vaultPath);
      final entries = await dir.list().toList();
      final allFiles = entries.whereType<File>().toList();

      final fullFiles = allFiles
          .where((f) =>
              f.path.endsWith('.enc') &&
              !f.path.endsWith('.thumb.enc'))
          .toList();

      final thumbPaths = allFiles
          .where((f) => f.path.endsWith('.thumb.enc'))
          .map((f) => f.path)
          .toSet();

      final loaded = <_VaultFile>[];
      for (final file in fullFiles) {
        final fileName = file.path.split('/').last;
        final name =
            fileName.substring(0, fileName.length - '.enc'.length);
        final ext = _extOf(fileName);
        final tp =
            '${file.path.substring(0, file.path.length - '.enc'.length)}.thumb.enc';

        Uint8List? thumbBytes;
        if (thumbPaths.contains(tp)) {
          try {
            thumbBytes = VaultCrypto.decryptBytes(
              await File(tp).readAsBytes(),
              widget.password,
              _salt,
            );
          } catch (_) {
            // Corrupt thumbnail; will be regenerated below.
          }
        }

        loaded.add(_VaultFile(
          path: file.path,
          name: name,
          ext: ext,
          isVideo: _videoExts.contains(ext),
          isImage: _imageExts.contains(ext),
          thumbBytes: thumbBytes,
        ));
      }

      if (mounted) {
        setState(() {
          media = loaded;
          _sortList();
          loading = false;
        });
      }

      // Files imported before thumbnails existed get theirs generated
      // in the background, one at a time (bounded memory).
      _generateMissingThumbs();
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Sorts [media] in place according to [_sortMode]. Call inside setState.
  void _sortList() {
    switch (_sortMode) {
      case 'oldest':
        media.sort((a, b) => a.path.compareTo(b.path));
        break;
      case 'name':
        media.sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      default: // newest
        media.sort((a, b) => b.path.compareTo(a.path));
    }
  }

  void _changeSort(String mode) {
    _sortMode = mode;
    Hive.box('settings').put('vault_sort', mode);
    setState(_sortList);
  }

  Future<void> _generateMissingThumbs() async {
    for (final item in media) {
      if (!item.isImage || item.thumbBytes != null) continue;
      try {
        final data = await File(item.path).readAsBytes();
        final plain =
            VaultCrypto.decryptBytes(data, widget.password, _salt);
        final thumb = _makeThumbnail(plain);
        if (thumb == null) continue;
        final encThumb = VaultCrypto.encryptBytes(
            thumb, widget.password, _salt);
        await File(item.thumbPath)
            .writeAsBytes(encThumb, flush: true);
        item.thumbBytes = thumb;
        if (mounted) setState(() {});
      } catch (_) {
        // Skip files that fail; tile keeps its placeholder.
      }
    }
  }

  // ------------------------------------------------------------------
  // Selection: select/deselect all, delete, move
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

  /// Tapping the select-all icon again deselects everything.
  void _toggleSelectAll() {
    setState(() {
      if (selectedIndexes.length == media.length &&
          media.isNotEmpty) {
        selectedIndexes.clear();
        selectionMode = false;
      } else {
        selectedIndexes =
            Set.from(List.generate(media.length, (i) => i));
        selectionMode = true;
      }
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
                  } catch (_) {}
                  try {
                    await File(item.thumbPath).delete();
                  } catch (_) {}
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
                        final thumbFile = File(item.thumbPath);
                        if (await thumbFile.exists()) {
                          final thumbName =
                              '${fileName.substring(0, fileName.length - '.enc'.length)}.thumb.enc';
                          await thumbFile.rename(
                              '${destDir.path}/$thumbName');
                        }
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

  PopupMenuItem<String> _sortMenuItem(String value, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            _sortMode == value
                ? Icons.check
                : Icons.check_box_outline_blank,
            size: 18,
            color: VaultTheme.accent,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style:
                const TextStyle(color: VaultTheme.textPrimary),
          ),
        ],
      ),
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
            items: media,
            initialIndex: index,
            password: widget.password,
            salt: _salt,
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
      final data = await File(item.path).readAsBytes();
      final plain =
          VaultCrypto.decryptBytes(data, widget.password, _salt);
      await File(path).writeAsBytes(plain, flush: true);
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
    } else if (file.thumbBytes != null) {
      content = Image.memory(file.thumbBytes!, fit: BoxFit.cover);
    } else if (file.isImage) {
      // Thumbnail still generating in the background.
      content = Container(
        color: VaultTheme.surfaceLight,
        child: const Icon(Icons.image_outlined,
            size: 32, color: VaultTheme.textSecondary),
      );
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
    final allSelected =
        media.isNotEmpty && selectedIndexes.length == media.length;

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
              icon: Icon(
                  allSelected ? Icons.deselect : Icons.select_all),
              tooltip:
                  allSelected ? "Deselect all" : "Select all",
              onPressed: _toggleSelectAll,
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
          ] else
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort,
                  color: VaultTheme.textPrimary),
              tooltip: "Sort",
              color: VaultTheme.surface,
              onSelected: _changeSort,
              itemBuilder: (_) => [
                _sortMenuItem('newest', "Newest first"),
                _sortMenuItem('oldest', "Oldest first"),
                _sortMenuItem('name', "Name"),
              ],
            ),
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

/// Full-screen viewer. The full file is decrypted on demand for the
/// currently visible page only; images show from memory, videos via a
/// temporary file that is deleted on close.
class FullScreenViewer extends StatefulWidget {
  final List<_VaultFile> items;
  final int initialIndex;
  final String password;
  final String salt;

  const FullScreenViewer({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.password,
    required this.salt,
  });

  @override
  State<FullScreenViewer> createState() => _FullScreenViewerState();
}

class _FullScreenViewerState extends State<FullScreenViewer> {
  late PageController controller;
  VideoPlayerController? _videoController;
  String? _tempVideoPath;
  int _current = 0;

  Uint8List? _fullBytes;
  bool _loadingFull = true;
  String? _loadError;

  // Video controls.
  bool _showControls = true;
  Timer? _hideTimer;
  bool _dragging = false;
  double _dragValue = 0;
  double _speed = 1.0;

  // Image zoom.
  final TransformationController _zoomController =
      TransformationController();
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    controller = PageController(initialPage: _current);
    _zoomController.addListener(_onZoomChanged);
    _loadCurrent();
  }

  void _onZoomChanged() {
    final zoomed =
        _zoomController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isZoomed && mounted) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _toggleZoom() {
    _zoomController.value = _isZoomed
        ? Matrix4.identity()
        : (Matrix4.identity()..scale(2.5));
  }

  void _onVideoTick() {
    if (mounted && _showControls && !_dragging) setState(() {});
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _loadCurrent() async {
    if (mounted) {
      setState(() {
        _loadingFull = true;
        _fullBytes = null;
        _loadError = null;
        _showControls = true;
        _dragging = false;
      });
    }
    _zoomController.value = Matrix4.identity();
    await _disposeVideo();

    try {
      final item = widget.items[_current];
      final data = await File(item.path).readAsBytes();
      final plain = VaultCrypto.decryptBytes(
          data, widget.password, widget.salt);
      if (!mounted) return;

      if (item.isVideo) {
        final tmp = await getTemporaryDirectory();
        final ext = item.ext.isEmpty ? '.mp4' : item.ext;
        final path =
            '${tmp.path}/vault_play_${DateTime.now().millisecondsSinceEpoch}$ext';
        await File(path).writeAsBytes(plain, flush: true);
        _tempVideoPath = path;
        _videoController = VideoPlayerController.file(File(path));
        _videoController!.addListener(_onVideoTick);
        await _videoController!.initialize();
        if (!mounted) return;
        await _videoController!.setPlaybackSpeed(_speed);
        setState(() => _loadingFull = false);
        _startHideTimer();
        await _videoController!.play();
      } else {
        setState(() {
          _fullBytes = plain;
          _loadingFull = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingFull = false;
          _loadError = "Couldn't open this file";
        });
      }
    }
  }

  void _seekBy(int seconds) {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > c.value.duration ? c.value.duration : target);
    c.seekTo(clamped);
  }

  void _togglePlay() {
    final c = _videoController;
    if (c == null) return;
    if (!c.value.isPlaying &&
        c.value.position >= c.value.duration &&
        c.value.duration > Duration.zero) {
      c.seekTo(Duration.zero); // replay from start
    }
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
    _startHideTimer();
  }

  Future<void> _disposeVideo() async {
    _videoController?.removeListener(_onVideoTick);
    await _videoController?.dispose();
    _videoController = null;
    _hideTimer?.cancel();
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
    _hideTimer?.cancel();
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    controller.dispose();
    _disposeVideo();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Info / delete
  // ------------------------------------------------------------------

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(
                    color: VaultTheme.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: VaultTheme.textPrimary)),
          ),
        ],
      ),
    );
  }

  Future<void> _showInfo() async {
    final item = widget.items[_current];
    String size = '—';
    String modified = '—';
    try {
      final stat = await File(item.path).stat();
      size = _formatSize(stat.size);
      modified =
          '${stat.modified.day}/${stat.modified.month}/${stat.modified.year}';
    } catch (_) {}
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text('File info',
            style:
                TextStyle(color: VaultTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Name', item.name),
            _infoRow('Type', item.isVideo ? 'Video' : 'Photo'),
            _infoRow('Size', size),
            _infoRow('Added', modified),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close',
                style: TextStyle(color: VaultTheme.accent)),
          ),
        ],
      ),
    );
  }

  void _deleteCurrent() {
    final item = widget.items[_current];
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text('Delete this file?',
            style:
                TextStyle(color: VaultTheme.textPrimary)),
        content: const Text(
          'This cannot be undone.',
          style: TextStyle(color: VaultTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                await File(item.path).delete();
              } catch (_) {}
              try {
                await File(item.thumbPath).delete();
              } catch (_) {}
              widget.items.removeAt(_current);
              if (!mounted) return;
              if (widget.items.isEmpty) {
                Navigator.pop(context);
                return;
              }
              final needsJump = _current >= widget.items.length;
              if (needsJump) {
                _current = widget.items.length - 1;
              }
              setState(() {});
              _loadCurrent();
              if (needsJump) controller.jumpToPage(_current);
            },
            child: const Text('Delete',
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  Widget _buildImage() {
    return GestureDetector(
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _zoomController,
        minScale: 1.0,
        maxScale: 5.0,
        child: Center(
          child: _fullBytes != null
              ? Image.memory(_fullBytes!)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final duration = c.value.duration;
    final position = c.value.position;
    final maxMs = max(1, duration.inMilliseconds).toDouble();
    final sliderValue =
        (_dragging ? _dragValue : position.inMilliseconds.toDouble())
            .clamp(0.0, maxMs);

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          if (_showControls) ...[
            IconButton(
              icon: Icon(
                c.value.isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: Colors.white.withOpacity(0.9),
                size: 64,
              ),
              onPressed: _togglePlay,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // Absorb taps here so they don't toggle the controls.
              child: GestureDetector(
                onTap: () {},
                behavior: HitTestBehavior.opaque,
                child: Container(
                padding:
                    const EdgeInsets.fromLTRB(8, 24, 8, 12),
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      value: sliderValue,
                      max: maxMs,
                      activeColor: VaultTheme.accent,
                      inactiveColor: Colors.white24,
                      onChangeStart: (v) {
                        _hideTimer?.cancel();
                        setState(() {
                          _dragging = true;
                          _dragValue = v;
                        });
                      },
                      onChanged: (v) =>
                          setState(() => _dragValue = v),
                      onChangeEnd: (v) {
                        setState(() => _dragging = false);
                        c.seekTo(Duration(
                            milliseconds: v.toInt()));
                        _startHideTimer();
                      },
                    ),
                    Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        Padding(
                          padding:
                              const EdgeInsets.only(left: 14),
                          child: Text(
                            '${_fmt(_dragging ? Duration(milliseconds: _dragValue.toInt()) : position)} / ${_fmt(duration)}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12),
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10,
                                  color: Colors.white),
                              tooltip: 'Back 10s',
                              onPressed: () => _seekBy(-10),
                            ),
                            IconButton(
                              icon: const Icon(Icons.forward_10,
                                  color: Colors.white),
                              tooltip: 'Forward 10s',
                              onPressed: () => _seekBy(10),
                            ),
                            PopupMenuButton<double>(
                              icon: const Icon(Icons.speed,
                                  color: Colors.white),
                              tooltip: 'Playback speed',
                              color: VaultTheme.surface,
                              initialValue: _speed,
                              onSelected: (v) {
                                setState(() => _speed = v);
                                c.setPlaybackSpeed(v);
                              },
                              itemBuilder: (_) => [
                                0.5,
                                1.0,
                                1.5,
                                2.0
                              ]
                                  .map(
                                    (s) => PopupMenuItem(
                                      value: s,
                                      child: Text(
                                        '${s}x',
                                        style: const TextStyle(
                                            color: VaultTheme
                                                .textPrimary),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (!_loadingFull && _loadError == null) ...[
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'File info',
              onPressed: _showInfo,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _deleteCurrent,
            ),
          ],
        ],
      ),
      body: PageView.builder(
        controller: controller,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: widget.items.length,
        onPageChanged: (i) {
          if (i == _current) return;
          _current = i;
          _loadCurrent();
        },
        itemBuilder: (_, i) {
          if (i != _current) {
            // Keep off-screen pages cheap.
            return const SizedBox.shrink();
          }

          if (_loadingFull) {
            return const Center(
                child: CircularProgressIndicator());
          }

          if (_loadError != null) {
            return Center(
              child: Text(
                _loadError!,
                style:
                    const TextStyle(color: Colors.white70),
              ),
            );
          }

          final item = widget.items[i];
          return item.isVideo ? _buildVideo() : _buildImage();
        },
      ),
    );
  }
}
