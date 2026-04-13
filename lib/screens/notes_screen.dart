import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import '../models/note_model.dart';
import 'edit_note_screen.dart';
import 'edit_checklist_screen.dart';
import 'vault_lock_screen.dart';

enum DrawerSection { notes, reminders, labels, archive, settings, help }

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  late Box<Note> box;

  String searchQuery = "";
  DrawerSection currentSection = DrawerSection.notes;

  final List<Color> noteColors = [
    const Color(0xFFFFF59D),
    const Color(0xFF80DEEA),
    const Color(0xFFFFAB91),
    const Color(0xFFCF93D9),
    const Color(0xFFA5D6A7),
    const Color(0xFF90CAF9),
  ];

  bool _isVaultOpening = false;

  @override
  void initState() {
    super.initState();
    box = Hive.box<Note>('notesBox');
  }

  void _openVault() {
    if (_isVaultOpening) return;

    _isVaultOpening = true;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const VaultLockScreen(),
      ),
    ).then((_) {
      _isVaultOpening = false;
    });
  }

  void openNote({Note? note}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditNoteScreen(note: note)),
    ).then((_) => setState(() {}));
  }

  void openChecklist(Note note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditChecklistScreen(note: note)),
    ).then((_) => setState(() {}));
  }

  void deleteNote(Note note) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete note?"),
        content: const Text("This action cannot be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              note.delete();
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text("Delete"),
          ),
        ],
      ),
    );
  }

  void toggleArchive(Note note) {
    final isNowArchived = !note.isArchived;

    note.isArchived = isNowArchived;
    note.save();
    setState(() {});

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(isNowArchived ? "Note archived" : "Moved to Notes"),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  void toggleReminder(Note note) {
    final isNowReminder = !note.isReminder;

    note.isReminder = isNowReminder;
    note.save();
    setState(() {});

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            isNowReminder ? "Added to Reminders" : "Removed from Reminders",
          ),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  void openChecklistNote() {
    final titleController = TextEditingController();
    List<TextEditingController> items = [TextEditingController()];
    List<FocusNode> focusNodes = [FocusNode()];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 16,
                  right: 16,
                  top: 16,
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(hintText: "Title"),
                    ),
                    const SizedBox(height: 10),
                    ...List.generate(items.length, (index) {
                      return Row(
                        children: [
                          const Icon(Icons.check_box_outline_blank),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: items[index],
                              focusNode: focusNodes[index],
                              decoration: const InputDecoration(
                                hintText: "Item",
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                    TextButton(
                      onPressed: () {
                        setModalState(() {
                          items.add(TextEditingController());
                          focusNodes.add(FocusNode());
                        });

                        Future.delayed(const Duration(milliseconds: 100), () {
                          focusNodes.last.requestFocus();
                        });
                      },
                      child: const Text("+ Add item"),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final List<Map> list = [];

                        for (var item in items) {
                          if (item.text.trim().isNotEmpty) {
                            list.add({"text": item.text.trim(), "done": false});
                          }
                        }

                        if (list.isEmpty) return;

                        box.add(
                          Note(
                            title: titleController.text,
                            content: "",
                            createdAt: DateTime.now(),
                            checklist: list,
                            isChecklist: true,
                            isReminder:
                                currentSection == DrawerSection.reminders,
                            isArchived: currentSection == DrawerSection.archive,
                          ),
                        );

                        Navigator.pop(context);
                        setState(() {});
                      },
                      child: const Text("Save"),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBody() {
    switch (currentSection) {
      case DrawerSection.notes:
      case DrawerSection.reminders:
      case DrawerSection.archive:
        return _buildNotesGrid();
      case DrawerSection.labels:
        return const Center(child: Text("Coming soon"));
      default:
        return const Center(child: Text("Coming soon"));
    }
  }

  Widget _buildNotesGrid() {
    final allNotes = box.values.toList().reversed.toList();

    final notes = allNotes.where((note) {
      if (currentSection == DrawerSection.notes && note.isArchived) {
        return false;
      }

      if (currentSection == DrawerSection.archive && !note.isArchived) {
        return false;
      }

      if (currentSection == DrawerSection.reminders && !note.isReminder) {
        return false;
      }

      return note.title.toLowerCase().contains(searchQuery.toLowerCase()) ||
          note.content.toLowerCase().contains(searchQuery.toLowerCase());
    }).toList();

    if (notes.isEmpty) {
      return const Center(child: Text("No notes"));
    }

    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.builder(
        itemCount: notes.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 180,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemBuilder: (_, i) {
          final n = notes[i];
          final color = noteColors[i % noteColors.length];

          return GestureDetector(
            onTap: () => n.isChecklist ? openChecklist(n) : openNote(note: n),
            onLongPress: () => deleteNote(n),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title.isEmpty ? "Untitled" : n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: n.isChecklist && n.checklist != null
                        ? Column(
                            children: () {
                              List<Widget> children = [];
                              int totalItems = n.checklist!.length;
                              int shownItems = totalItems > 2 ? 2 : totalItems;
                              for (int i = 0; i < shownItems; i++) {
                                var item = n.checklist![i];
                                children.add(
                                  Row(
                                    children: [
                                      Icon(
                                        item["done"]
                                            ? Icons.check_box
                                            : Icons.check_box_outline_blank,
                                        size: 16,
                                      ),
                                      Expanded(
                                        child: Text(
                                          item["text"],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              if (totalItems > 2) {
                                children.add(Text("+${totalItems - 2} more"));
                              }
                              return children;
                            }(),
                          )
                        : Text(
                            n.content,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(
                          n.isReminder
                              ? Icons.notifications_active
                              : Icons.notifications_none,
                          size: 18,
                        ),
                        onPressed: () => toggleReminder(n),
                      ),
                      IconButton(
                        icon: Icon(
                          n.isArchived ? Icons.unarchive : Icons.archive,
                          size: 18,
                        ),
                        onPressed: () => toggleArchive(n),
                      ),
                    ],
                  ),
                  Text(
                    DateFormat.yMMMd().format(n.createdAt),
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: ListView(
          children: [
            const SizedBox(
              height: 80,
              child: DrawerHeader(
                child: Text("My Notes", style: TextStyle(fontSize: 30)),
              ),
            ),
            _drawerItem(Icons.note, "Notes", DrawerSection.notes),
            _drawerItem(Icons.label, "Labels", DrawerSection.labels),
            _drawerItem(
              Icons.notifications,
              "Reminders",
              DrawerSection.reminders,
            ),
            _drawerItem(Icons.archive, "Archive", DrawerSection.archive),
            _drawerItem(Icons.settings, "Settings", DrawerSection.settings),
            _drawerItem(Icons.help, "Help & Feedback", DrawerSection.help),
          ],
        ),
      ),
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(
            hintText: "Search notes...",
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => searchQuery = v),
        ),
      ),

      // ✅ FIXED HERE
      body: GestureDetector(
        behavior: HitTestBehavior.translucent, 
        onScaleUpdate: (details) {
          if (details.scale < 0.7 && details.pointerCount == 2) {
            _openVault();
          }
        },
        child: SizedBox( // 🔥 REQUIRED
          width: double.infinity,
          height: double.infinity,
        child: _buildBody(),
      ),
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            builder: (_) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildOption(Icons.text_fields, "Text", () {
                      Navigator.pop(context);
                      openNote();
                    }),
                    _buildOption(Icons.check_box, "List", () {
                      Navigator.pop(context);
                      openChecklistNote();
                    }),
                  ],
                ),
              );
            },
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildOption(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: Colors.grey.shade200,
            child: Icon(icon),
          ),
          const SizedBox(height: 6),
          Text(label),
        ],
      ),
    );
  }

  Widget _drawerItem(IconData icon, String title, DrawerSection section) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      selected: currentSection == section,
      onTap: () {
        setState(() => currentSection = section);
        Navigator.pop(context);
      },
    );
  }
}