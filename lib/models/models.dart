/// Моделі даних розкладу КНУ (система МКР / ПС-Розклад).

class Faculty {
  final int id;
  final String name;

  const Faculty({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Faculty.fromJson(Map<String, dynamic> j) => Faculty(
        id: j['id'] as int,
        name: j['name'] as String,
      );

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) => other is Faculty && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class Group {
  final int id;
  final String name;
  final int facultyId;
  final String facultyName;
  final int course;

  const Group({
    required this.id,
    required this.name,
    required this.facultyId,
    required this.facultyName,
    required this.course,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'facultyId': facultyId,
        'facultyName': facultyName,
        'course': course,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as int,
        name: j['name'] as String,
        facultyId: j['facultyId'] as int,
        facultyName: j['facultyName'] as String,
        course: j['course'] as int,
      );

  String get displayLabel => '$name · $facultyName · $course курс';

  @override
  bool operator ==(Object other) =>
      other is Group && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Одна пара в конкретний день.
class Lesson {
  final int pairNumber;
  final String timeStart;
  final String timeEnd;
  final String date; // dd.MM.yyyy
  final String subjectShort;
  final String subjectFull;
  final String lessonType; // Лк, Лб, Пр...
  final String classroom;
  final String teacher;
  final String teacherFull;
  final int? adsR1; // код для оголошень
  final String? adsDate; // r2

  const Lesson({
    required this.pairNumber,
    required this.timeStart,
    required this.timeEnd,
    required this.date,
    required this.subjectShort,
    required this.subjectFull,
    required this.lessonType,
    required this.classroom,
    required this.teacher,
    required this.teacherFull,
    this.adsR1,
    this.adsDate,
  });

  bool get hasAds => adsR1 != null;

  String get typeLabel {
    switch (lessonType.toLowerCase()) {
      case 'лк':
        return 'Лекція';
      case 'лб':
        return 'Лабораторна';
      case 'пр':
        return 'Практика';
      case 'сем':
        return 'Семінар';
      default:
        return lessonType.isEmpty ? 'Заняття' : lessonType;
    }
  }
}

class DaySchedule {
  final String date; // dd.MM.yyyy
  final String weekday; // Пн, Вт...
  final List<Lesson> lessons;

  const DaySchedule({
    required this.date,
    required this.weekday,
    required this.lessons,
  });
}

class ScheduleResult {
  final Group group;
  final List<DaySchedule> days;
  final DateTime loadedAt;

  const ScheduleResult({
    required this.group,
    required this.days,
    required this.loadedAt,
  });

  List<Lesson> lessonsForDate(String date) {
    for (final d in days) {
      if (d.date == date) return d.lessons;
    }
    return const [];
  }
}
