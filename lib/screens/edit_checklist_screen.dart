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

  @override
  void initState() {
    super.initState();

    titleController = TextEditingController(text: widget.note.title);

    checklist = List<Map>.from(widget.note.checklist ?? []);
  }

  void addItem() {
    setState(() {
      checklist.add({"text": "", "done": false});
    });
  }

  void saveChecklist() {
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
                    controller: TextEditingController(text: item["text"]),
                    onChanged: (val) {
                      item["text"] = val;
                    },
                    decoration: const InputDecoration(border: InputBorder.none),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      checklist.removeAt(index);
                    });
                  },
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
