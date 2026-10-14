import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../security/vault_crypto.dart';
import 'vault_theme.dart';

class _IntruderPhoto {
  final String path;
  final int timestampMs;
  Uint8List? bytes;

  _IntruderPhoto({
    required this.path,
    required this.timestampMs,
    this.bytes,
  });
}

/// Shows the encrypted front-camera photos captured after repeated wrong
/// vault passwords. Photos are decrypted with the salt-derived intruder
/// key (never the vault password, which was unknown at capture time).
class IntruderLogScreen extends StatefulWidget {
  const IntruderLogScreen({super.key});

  @override
  State<IntruderLogScreen> createState() => _IntruderLogScreenState();
}

class _IntruderLogScreenState extends State<IntruderLogScreen> {
  List<_IntruderPhoto> photos = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final loaded = <_IntruderPhoto>[];
    try {
      final salt =
          VaultCrypto.getOrCreateSalt(Hive.box('settings'));
      final key = VaultCrypto.intruderKey(salt);
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/vault/.intruder');
      if (await dir.exists()) {
        final files = await dir.list().toList();
        for (final e in files) {
          if (e is! File || !e.path.endsWith('.enc')) continue;
          final name = e.path.split('/').last;
          final ts = int.tryParse(
                  name.substring(0, name.length - '.enc'.length)) ??
              0;
          Uint8List? bytes;
          try {
            bytes = VaultCrypto.decryptWithKey(
              await e.readAsBytes(),
              key,
            );
          } catch (_) {
            // Corrupt entry: show the tile without an image.
          }
          loaded.add(_IntruderPhoto(
            path: e.path,
            timestampMs: ts,
            bytes: bytes,
          ));
        }
      }
    } catch (_) {}
    loaded.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    if (mounted) {
      setState(() {
        photos = loaded;
        loading = false;
      });
    }
  }

  String _formatTime(int ms) {
    if (ms == 0) return 'Unknown time';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final day = d.day.toString().padLeft(2, '0');
    final mon = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$day/$mon/${d.year} $hh:$mm';
  }

  void _viewPhoto(_IntruderPhoto photo) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: VaultTheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photo.bytes != null)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12)),
                child: Image.memory(photo.bytes!),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatTime(photo.timestampMs),
                    style: const TextStyle(
                        color: VaultTheme.textSecondary),
                  ),
                  TextButton(
                    onPressed: () async {
                      try {
                        await File(photo.path).delete();
                      } catch (_) {}
                      Navigator.pop(dialogContext);
                      _load();
                    },
                    child: const Text("Delete",
                        style:
                            TextStyle(color: VaultTheme.danger)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _clearAll() {
    if (photos.isEmpty) return;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: VaultTheme.surface,
        title: const Text("Clear intruder log?",
            style: TextStyle(color: VaultTheme.textPrimary)),
        content: Text(
          "Delete all ${photos.length} intruder photo(s)?",
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
              for (final p in photos) {
                try {
                  await File(p.path).delete();
                } catch (_) {}
              }
              _load();
            },
            child: const Text("Delete all",
                style: TextStyle(color: VaultTheme.danger)),
          ),
        ],
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
        iconTheme:
            const IconThemeData(color: VaultTheme.textPrimary),
        title: const Text(
          "Intruder Log",
          style: TextStyle(
            color: VaultTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (photos.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined,
                  color: VaultTheme.danger),
              tooltip: "Clear all",
              onPressed: _clearAll,
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : photos.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.camera_front_outlined,
                          size: 48,
                          color: VaultTheme.textSecondary),
                      SizedBox(height: 12),
                      Text(
                        "No intruder attempts recorded",
                        style: TextStyle(
                            color: VaultTheme.textSecondary),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: photos.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    mainAxisExtent: 210,
                  ),
                  itemBuilder: (_, i) {
                    final p = photos[i];
                    return GestureDetector(
                      onTap: () => _viewPhoto(p),
                      child: Container(
                        decoration:
                            VaultTheme.cardDecoration(),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                              VaultTheme.cardRadius),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: p.bytes != null
                                    ? Image.memory(p.bytes!,
                                        fit: BoxFit.cover)
                                    : Container(
                                        color: VaultTheme
                                            .surfaceLight,
                                        child: const Icon(
                                          Icons
                                              .broken_image_outlined,
                                          color: VaultTheme
                                              .textSecondary,
                                        ),
                                      ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.all(8),
                                child: Text(
                                  _formatTime(p.timestampMs),
                                  style: const TextStyle(
                                    color: VaultTheme
                                        .textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
