import 'package:hive/hive.dart';

part 'note_model.g.dart';

@HiveType(typeId: 0)
class Note extends HiveObject {
  @HiveField(0)
  String title;

  @HiveField(1)
  String content;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  List<Map>? checklist;

  @HiveField(4)
  bool isChecklist;

  @HiveField(5)
  bool isArchived;

  @HiveField(6) // 🔥 NEW (simple reminder flag)
  bool isReminder;

  Note({
    required this.title,
    required this.content,
    required this.createdAt,
    this.checklist,
    this.isChecklist = false,
    this.isArchived = false,
    this.isReminder = false, // 🔥 default
  });
}