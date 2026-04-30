import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

class AlbumScreen extends StatefulWidget {
  final String albumName;

  const AlbumScreen({super.key, required this.albumName});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<File> media = [];
  Set<int> selectedIndexes = {};

  bool selectionMode = false;

  Future<String> _getVaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/vault/${widget.albumName}';

    final folder = Directory(path);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    return path;
  }

  Future<File> _saveFile(File original) async {
    final vaultPath = await _getVaultPath();

    final name = DateTime.now().millisecondsSinceEpoch.toString();
    final newPath = '$vaultPath/$name';

    return await original.copy(newPath);
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.media,
    );

    if (result == null) return;

    for (var file in result.files) {
      if (file.path != null) {
        final saved = await _saveFile(File(file.path!));
        media.add(saved);
      }
    }

    setState(() {});
  }

  Future<void> _loadMedia() async {
    final path = await _getVaultPath();
    final dir = Directory(path);

    final files = dir.listSync();

    media = files.whereType<File>().toList();

    setState(() {});
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
    for (var i in selectedIndexes) {
      media[i].deleteSync();
    }

    setState(() {
      media.removeWhere((file) =>
          selectedIndexes.contains(media.indexOf(file)));

      selectedIndexes.clear();
      selectionMode = false;
    });
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

  bool _isVideo(File file) {
    return file.path.endsWith(".mp4") ||
        file.path.endsWith(".mov") ||
        file.path.endsWith(".avi");
  }

  @override
  void initState() {
    super.initState();
    _loadMedia();
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
      body: media.isEmpty
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
                        child: _isVideo(file)
                            ? Container(
                                color: Colors.black12,
                                child: const Icon(Icons.video_file),
                              )
                            : Image.file(file, fit: BoxFit.cover),
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

class FullScreenViewer extends StatefulWidget {
  final List<File> media;
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

  @override
  void initState() {
    super.initState();
    controller = PageController(initialPage: widget.initialIndex);
  }

  bool _isVideo(File file) {
    return file.path.endsWith(".mp4") ||
        file.path.endsWith(".mov") ||
        file.path.endsWith(".avi");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: controller,
        itemCount: widget.media.length,
        itemBuilder: (_, i) {
          final file = widget.media[i];

          return Center(
            child: _isVideo(file)
                ? const Icon(Icons.video_file,
                    color: Colors.white, size: 100)
                : Image.file(file),
          );
        },
      ),
    );
  }
}