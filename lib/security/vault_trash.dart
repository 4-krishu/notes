import 'dart:io';

import 'vault_prefs.dart';

/// One item sitting in the trash.
class TrashItem {
  /// Encrypted file name inside the .trash folder.
  final String trashName;

  /// Original album (or '.notes' for vault text notes).
  final String album;

  /// Deletion time, ms since epoch (0 if unknown).
  final int deletedAt;

  /// 'file' | 'note'.
  final String kind;

  final int size;

  TrashItem({
    required this.trashName,
    required this.album,
    required this.deletedAt,
    required this.kind,
    required this.size,
  });

  /// "X.jpg.enc" -> "X.jpg.thumb.enc"
  String get thumbName => VaultTrash.thumbNameFor(trashName);

  /// File name without the .enc suffix, for display.
  String get displayName {
    var n = trashName;
    if (n.endsWith('.note.enc')) {
      n = n.substring(0, n.length - '.note.enc'.length);
    } else if (n.endsWith('.enc')) {
      n = n.substring(0, n.length - '.enc'.length);
    }
    return n;
  }

  bool get isNote => kind == 'note';

  /// Whole days until permanent deletion.
  int get daysLeft {
    if (deletedAt == 0) return VaultTrash.keepDays;
    final elapsedMs =
        DateTime.now().millisecondsSinceEpoch - deletedAt;
    final left =
        VaultTrash.keepDays - elapsedMs ~/ (24 * 3600 * 1000);
    return left < 0 ? 0 : left;
  }
}

/// Trash bin: deleted files rest here — still encrypted, untouched —
/// for 30 days before being permanently deleted.
class VaultTrash {
  static const int keepDays = 30;

  /// "<dir>/X.jpg.enc" -> "<dir>/X.jpg.thumb.enc"
  static String thumbPathFor(String encPath) =>
      '${encPath.substring(0, encPath.length - '.enc'.length)}.thumb.enc';

  static String thumbNameFor(String encName) =>
      '${encName.substring(0, encName.length - '.enc'.length)}.thumb.enc';

  /// Moves encrypted files (full `.enc` files; their `.thumb.enc`
  /// companions follow automatically) into [trashDir]. Files are NOT
  /// re-encrypted: encryption is password-based, not location-based.
  static Future<void> moveFilesToTrash({
    required List<String> encPaths,
    required Directory trashDir,
    required String albumName,
  }) async {
    final meta = VaultPrefs.getTrashMeta();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final p in encPaths) {
      final src = File(p);
      if (!await src.exists()) continue;

      final base = p.split('/').last;
      var destName = base;
      var n = 1;
      while (await File('${trashDir.path}/$destName').exists()) {
        final dot = base.lastIndexOf('.');
        destName =
            '${base.substring(0, dot)}_$n${base.substring(dot)}';
        n++;
      }

      await src.rename('${trashDir.path}/$destName');

      // Companion thumbnail follows under the matching name.
      final srcThumb = File(thumbPathFor(p));
      if (await srcThumb.exists()) {
        try {
          await srcThumb
              .rename('${trashDir.path}/${thumbNameFor(destName)}');
        } catch (_) {}
      }

      meta[destName] = {
        'album': albumName,
        'deletedAt': now,
        'kind': destName.endsWith('.note.enc') ? 'note' : 'file',
      };
    }
    VaultPrefs.setTrashMeta(meta);
  }

  /// Every trash item, newest first. Thumbnails are folded into their file.
  static Future<List<TrashItem>> listItems(
      Directory trashDir) async {
    final items = <TrashItem>[];
    if (!await trashDir.exists()) return items;
    final meta = VaultPrefs.getTrashMeta();

    await for (final e in trashDir.list()) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      if (!name.endsWith('.enc') || name.endsWith('.thumb.enc')) {
        continue;
      }
      final m = meta[name];
      int size = 0;
      try {
        size = await e.length();
      } catch (_) {}
      items.add(TrashItem(
        trashName: name,
        album: (m?['album'] as String?) ?? 'Unknown',
        deletedAt: (m?['deletedAt'] as int?) ?? 0,
        kind: (m?['kind'] as String?) ?? 'file',
        size: size,
      ));
    }
    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return items;
  }

  /// Moves a trash item back to its original album (or the vault notes
  /// folder for notes). If the album no longer exists it is recreated.
  static Future<void> restoreItem({
    required TrashItem item,
    required Directory trashDir,
    required Future<Directory> Function(String album) albumDirFor,
  }) async {
    final destDir = await albumDirFor(item.album);

    var destName = item.trashName;
    var n = 1;
    while (await File('${destDir.path}/$destName').exists()) {
      final dot = item.trashName.lastIndexOf('.');
      destName =
          '${item.trashName.substring(0, dot)}_restored$n${item.trashName.substring(dot)}';
      n++;
    }

    await File('${trashDir.path}/${item.trashName}')
        .rename('${destDir.path}/$destName');

    final thumb = File('${trashDir.path}/${item.thumbName}');
    if (await thumb.exists()) {
      try {
        await thumb.rename(
            '${destDir.path}/${thumbNameFor(destName)}');
      } catch (_) {}
    }

    final meta = VaultPrefs.getTrashMeta()..remove(item.trashName);
    VaultPrefs.setTrashMeta(meta);
  }

  /// Permanently deletes a trash item and its thumbnail.
  static Future<void> deletePermanently(
      TrashItem item, Directory trashDir) async {
    try {
      await File('${trashDir.path}/${item.trashName}').delete();
    } catch (_) {}
    try {
      await File('${trashDir.path}/${item.thumbName}').delete();
    } catch (_) {}
    final meta = VaultPrefs.getTrashMeta()..remove(item.trashName);
    VaultPrefs.setTrashMeta(meta);
  }

  /// Permanently deletes items older than [keepDays]. Returns how many
  /// were removed. Also drops metadata for files that no longer exist.
  static Future<int> purgeExpired(Directory trashDir) async {
    final items = await listItems(trashDir);
    final cutoff = DateTime.now().millisecondsSinceEpoch -
        keepDays * 24 * 3600 * 1000;

    var removed = 0;
    for (final it in items) {
      if (it.deletedAt != 0 && it.deletedAt < cutoff) {
        await deletePermanently(it, trashDir);
        removed++;
      }
    }

    final alive = (await listItems(trashDir))
        .map((e) => e.trashName)
        .toSet();
    final meta = VaultPrefs.getTrashMeta()
      ..removeWhere((k, _) => !alive.contains(k));
    VaultPrefs.setTrashMeta(meta);

    return removed;
  }
}
