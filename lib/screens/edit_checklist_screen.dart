import 'package:flutter/material.dart';
import '../models/note_model.dart';

class EditChecklistScreen extends StatefulWidget {
  final Note note;

  const EditChecklistScreen({super.key, required this.note});

  @override
  State<EditChecklistScreen> createState() => _EditChecklistScreenState();
}

class _EditChecklistScreenState extends State<EditChecklistScreen> {
  late TextEditingController titleController;
  late List<Map> checklist;

  /// One controller per item, owned by the state (not rebuilt every frame),
  /// so typing never loses cursor position or text on rebuild.
  final List<TextEditingController> _itemControllers = [];

  @override
  void initState() {
    super.initState();

    titleController = TextEditingController(text: widget.note.title);

    checklist = List<Map>.from(widget.note.checklist ?? []);
    for (final item in checklist) {
      _itemControllers.add(
        TextEditingController(text: item["text"]?.toString() ?? ""),
      );
    }
  }

  @override
  void dispose() {
    titleController.dispose();
    for (final c in _itemControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void addItem() {
    setState(() {
      checklist.add({"text": "", "done": false});
      _itemControllers.add(TextEditingController());
    });
  }

  void removeItem(int index) {
    setState(() {
      _itemControllers[index].dispose();
      _itemControllers.removeAt(index);
      checklist.removeAt(index);
    });
  }

  void saveChecklist() {
    for (var i = 0; i < checklist.length; i++) {
      checklist[i]["text"] = _itemControllers[i].text;
    }

    widget.note.title = titleController.text;
    widget.note.checklist = checklist;
    widget.note.save();

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Edit Checklist"),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: saveChecklist),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // TITLE
          TextField(
            controller: titleController,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: const InputDecoration(
              hintText: "Title",
              border: InputBorder.none,
            ),
          ),

          const SizedBox(height: 10),

          // ITEMS
          ...List.generate(checklist.length, (index) {
            final item = checklist[index];

            return Row(
              children: [
                Checkbox(
                  value: item["done"] == true,
                  onChanged: (val) {
                    setState(() {
                      item["done"] = val;
                    });
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _itemControllers[index],
                    decoration: const InputDecoration(border: InputBorder.none),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => removeItem(index),
                ),
              ],
            );
          }),

          const SizedBox(height: 10),

          TextButton(onPressed: addItem, child: const Text("+ Add item")),
        ],
      ),
    );
  }
}
