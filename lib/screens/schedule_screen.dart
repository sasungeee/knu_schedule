import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/knu_api.dart';

class ScheduleScreen extends StatefulWidget {
  final Group group;
  final KnuApi api;

  const ScheduleScreen({super.key, required this.group, required this.api});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen>
    with SingleTickerProviderStateMixin {
  ScheduleResult? _schedule;
  bool _loading = true;
  String? _error;
  late TabController _tabs;
  int _dayIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await widget.api.getSchedule(widget.group);
      if (!mounted) return;
      // Сортуємо строго за DateTime (не рядком — інакше 10.11 перед 13.10).
      final sortedDays = List<DaySchedule>.from(s.days)
        ..sort((a, b) {
          final da = _parseDate(a.date);
          final db = _parseDate(b.date);
          if (da != null && db != null) return da.compareTo(db);
          if (da != null) return -1;
          if (db != null) return 1;
          return a.date.compareTo(b.date);
        });
      final sorted = ScheduleResult(
        group: s.group,
        days: sortedDays,
        loadedAt: s.loadedAt,
      );
      final today = DateFormat('dd.MM.yyyy').format(DateTime.now());
      var idx = sorted.days.indexWhere((d) => d.date == today);
      // Якщо сьогодні немає — перший день >= сьогодні, інакше 0.
      if (idx < 0) {
        final now = DateTime.now();
        final todayOnly = DateTime(now.year, now.month, now.day);
        idx = sorted.days.indexWhere((d) {
          final dt = _parseDate(d.date);
          return dt != null && !dt.isBefore(todayOnly);
        });
        if (idx < 0) idx = 0;
      }
      setState(() {
        _schedule = sorted;
        _dayIndex = idx.clamp(0, (sorted.days.length - 1).clamp(0, 999));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _showAds(Lesson lesson) async {
    if (!lesson.hasAds) return;

    // Нова розмітка: текст у adsDate (HTML/plain).
    // Стара: adsR1 + adsDate = коди для /time-table/show-ads.
    final adsPayload = lesson.adsDate ?? '';
    final bool looksLikeOldCodes = lesson.adsR1 != null &&
        lesson.adsR1 != 1 &&
        adsPayload.length <= 24 &&
        !adsPayload.contains('<') &&
        !adsPayload.contains('http');

    late final String text;
    if (!looksLikeOldCodes) {
      text = adsPayload
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      try {
        text = await widget.api.getAds(
          r1: lesson.adsR1!,
          r2: adsPayload,
        );
        if (!mounted) return;
        Navigator.of(context).pop();
      } catch (e) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка: $e')),
        );
        return;
      }
    }

    if (!mounted) return;
    final urls = _extractUrls(text);
    // Прибираємо URL з тексту, якщо показуємо окремі кнопки — без дублів.
    var displayText = text;
    if (urls.isNotEmpty) {
      for (final u in urls) {
        displayText = displayText.replaceAll(u, '').trim();
      }
      displayText = displayText
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Оголошення',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              Text(
                '${lesson.subjectShort} · ${lesson.date}',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (displayText.isNotEmpty)
                SelectableText(
                  displayText,
                  style: Theme.of(ctx).textTheme.bodyMedium,
                )
              else if (urls.isEmpty)
                Text(
                  'Немає тексту оголошення',
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
              if (urls.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...urls.map(
                  (u) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: () => launchUrl(
                        Uri.parse(u),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(
                        u,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  List<String> _extractUrls(String text) {
    final re = RegExp(r'https?://[^\s<>\)\]]+', caseSensitive: false);
    // Нормалізуємо (прибираємо хвіст пунктуації) і унікалізуємо.
    final seen = <String>{};
    final out = <String>[];
    for (final m in re.allMatches(text)) {
      var u = m.group(0)!;
      while (u.isNotEmpty && '.,;:!?'.contains(u[u.length - 1])) {
        u = u.substring(0, u.length - 1);
      }
      if (u.isNotEmpty && seen.add(u)) out.add(u);
    }
    return out;
  }

  DateTime? _parseDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    final dmy = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(s);
    if (dmy != null) {
      try {
        return DateTime(
          int.parse(dmy.group(3)!),
          int.parse(dmy.group(2)!),
          int.parse(dmy.group(1)!),
        );
      } catch (_) {}
    }

    final iso = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
    if (iso != null) {
      try {
        return DateTime(
          int.parse(iso.group(1)!),
          int.parse(iso.group(2)!),
          int.parse(iso.group(3)!),
        );
      } catch (_) {}
    }

    // «13 жовтня», «10 листопада 2026», «2 листопада»
    final uk = RegExp(
      r'(\d{1,2})\s*([а-яіїєґА-ЯІЇЄҐ]+)\s*(\d{4})?',
      unicode: true,
    ).firstMatch(s);
    if (uk != null) {
      final day = int.tryParse(uk.group(1)!);
      final monthWord = uk.group(2)!.toLowerCase();
      final yearStr = uk.group(3);
      int? month;
      if (monthWord.startsWith('лист')) {
        month = 11;
      } else if (monthWord.startsWith('лип')) {
        month = 7;
      } else if (monthWord.startsWith('січ')) {
        month = 1;
      } else if (monthWord.startsWith('лют')) {
        month = 2;
      } else if (monthWord.startsWith('бер')) {
        month = 3;
      } else if (monthWord.startsWith('квіт')) {
        month = 4;
      } else if (monthWord.startsWith('трав')) {
        month = 5;
      } else if (monthWord.startsWith('черв')) {
        month = 6;
      } else if (monthWord.startsWith('серп')) {
        month = 8;
      } else if (monthWord.startsWith('вер')) {
        month = 9;
      } else if (monthWord.startsWith('жовт')) {
        month = 10;
      } else if (monthWord.startsWith('груд')) {
        month = 12;
      }
      if (day != null && month != null) {
        final year = yearStr != null ? int.parse(yearStr) : DateTime.now().year;
        // Якщо дата без року і вийшла далеко в минулому відносно «сьогодні»
        // у січні для «грудня» — вважаємо попередній рік.
        var dt = DateTime(year, month, day);
        if (yearStr == null) {
          final now = DateTime.now();
          if (dt.difference(now).inDays > 180) {
            dt = DateTime(year - 1, month, day);
          } else if (now.difference(dt).inDays > 180) {
            dt = DateTime(year + 1, month, day);
          }
        }
        return dt;
      }
    }

    return DateTime.tryParse(s);
  }

  /// Короткий підпис чіпа: «13 жовт».
  String _chipLabel(DaySchedule d) {
    final dt = _parseDate(d.date);
    if (dt != null) {
      const short = [
        '',
        'січ',
        'лют',
        'бер',
        'квіт',
        'трав',
        'черв',
        'лип',
        'серп',
        'вер',
        'жовт',
        'лист',
        'груд',
      ];
      final wd = d.weekday.isNotEmpty
          ? d.weekday
          : const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'][dt.weekday - 1];
      return '$wd ${dt.day} ${short[dt.month]}';
    }
    // fallback
    final dayNum = d.date.length >= 5 ? d.date.substring(0, 5) : d.date;
    return '${d.weekday} $dayNum'.trim();
  }

  static const _ukMonths = [
    '',
    'січень',
    'лютий',
    'березень',
    'квітень',
    'травень',
    'червень',
    'липень',
    'серпень',
    'вересень',
    'жовтень',
    'листопад',
    'грудень',
  ];

  String _monthLabel(DateTime m) =>
      '${_ukMonths[m.month]} ${m.year}';

  /// Текст розкладу за вибраний місяць (для копіювання / «завантаження»).
  String _formatMonthText(int year, int month) {
    final g = widget.group;
    final buf = StringBuffer();
    buf.writeln('Розклад: ${g.name}');
    buf.writeln('${g.course} курс · ${g.facultyName}');
    buf.writeln(_monthLabel(DateTime(year, month)));
    buf.writeln('─' * 40);

    final days = _schedule?.days ?? const <DaySchedule>[];
    final filtered = days.where((d) {
      final dt = _parseDate(d.date);
      return dt != null && dt.year == year && dt.month == month;
    }).toList();

    if (filtered.isEmpty) {
      buf.writeln('Немає занять у цьому місяці.');
      return buf.toString();
    }

    for (final d in filtered) {
      buf.writeln();
      buf.writeln('${d.weekday} ${d.date}');
      if (d.lessons.isEmpty) {
        buf.writeln('  (пар немає)');
        continue;
      }
      for (final l in d.lessons) {
        final time = [
          if (l.timeStart.isNotEmpty) l.timeStart,
          if (l.timeEnd.isNotEmpty) l.timeEnd,
        ].join('–');
        final pair = l.pairNumber > 0 ? '${l.pairNumber} пара' : '';
        final head = [pair, if (time.isNotEmpty) time].join(' · ');
        buf.writeln('  ${head.isEmpty ? '•' : head}');
        final subj = l.subjectFull.isNotEmpty ? l.subjectFull : l.subjectShort;
        final type = l.lessonType.isNotEmpty ? ' [${l.lessonType}]' : '';
        buf.writeln('    $subj$type');
        if (l.classroom.isNotEmpty) buf.writeln('    ауд. ${l.classroom}');
        if (l.teacher.isNotEmpty) {
          buf.writeln(
            '    ${l.teacherFull.isNotEmpty ? l.teacherFull : l.teacher}',
          );
        }
      }
    }
    buf.writeln();
    buf.writeln('─' * 40);
    buf.writeln(
      'Оновлено: ${DateFormat('dd.MM.yyyy HH:mm').format(_schedule!.loadedAt)}',
    );
    return buf.toString();
  }

  Future<void> _downloadMonth() async {
    final schedule = _schedule;
    if (schedule == null || schedule.days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Спочатку завантажте розклад')),
      );
      return;
    }

    // Унікальні місяці з розкладу.
    final months = <String, DateTime>{};
    for (final d in schedule.days) {
      final dt = _parseDate(d.date);
      if (dt == null) continue;
      final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
      months.putIfAbsent(key, () => DateTime(dt.year, dt.month));
    }
    if (months.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Немає дат у розкладі')),
      );
      return;
    }

    final sorted = months.values.toList()..sort();
    final now = DateTime.now();
    DateTime initial = sorted.firstWhere(
      (m) => m.year == now.year && m.month == now.month,
      orElse: () => sorted.firstWhere(
        (m) => !m.isBefore(DateTime(now.year, now.month)),
        orElse: () => sorted.last,
      ),
    );

    final chosen = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'Завантажити розклад на місяць',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  itemBuilder: (_, i) {
                    final m = sorted[i];
                    final label = _monthLabel(m);
                    final selected =
                        m.year == initial.year && m.month == initial.month;
                    return ListTile(
                      leading: Icon(
                        selected
                            ? Icons.calendar_month
                            : Icons.calendar_month_outlined,
                      ),
                      title: Text(label),
                      trailing: selected
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () => Navigator.pop(ctx, m),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;

    final text = _formatMonthText(chosen.year, chosen.month);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, scrollCtrl) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _monthLabel(chosen),
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  Text(
                    'Скопійовано в буфер обміну',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollCtrl,
                      child: SelectableText(
                        text,
                        style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                              height: 1.35,
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопійовано')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Копіювати ще раз'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(g.name, style: const TextStyle(fontSize: 18)),
            Text(
              '${g.course} курс · ${g.facultyName}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Завантажити розклад на місяць',
            onPressed: _loading || _schedule == null ? null : _downloadMonth,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          IconButton(
            tooltip: 'Оновити',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'По днях'),
            Tab(text: 'Список'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('Повторити')),
                      ],
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildDayView(),
                    _buildListView(),
                  ],
                ),
    );
  }

  Widget _buildDayView() {
    final days = _schedule?.days ?? [];
    if (days.isEmpty) {
      return const Center(child: Text('Розклад порожній або ще не опублікований'));
    }
    final day = days[_dayIndex.clamp(0, days.length - 1)];
    return Column(
      children: [
        SizedBox(
          height: 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: days.length,
            itemBuilder: (context, i) {
              final d = days[i];
              final selected = i == _dayIndex;
              final chipText = _chipLabel(d);
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    chipText,
                    style: const TextStyle(fontSize: 13),
                  ),
                  selected: selected,
                  onSelected: (_) => setState(() => _dayIndex = i),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: day.lessons.isEmpty
              ? const Center(child: Text('Немає пар цього дня'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: day.lessons.length,
                  itemBuilder: (context, i) =>
                      _LessonCard(lesson: day.lessons[i], onAds: _showAds),
                ),
        ),
      ],
    );
  }

  Widget _buildListView() {
    final days = _schedule?.days ?? [];
    if (days.isEmpty) {
      return const Center(child: Text('Розклад порожній'));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: days.length,
      itemBuilder: (context, i) {
        final d = days[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '${d.weekday}, ${d.date}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            if (d.lessons.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Вихідний / немає пар'),
              )
            else
              ...d.lessons.map(
                (l) => _LessonCard(lesson: l, onAds: _showAds),
              ),
          ],
        );
      },
    );
  }
}

class _LessonCard extends StatelessWidget {
  final Lesson lesson;
  final Future<void> Function(Lesson) onAds;

  const _LessonCard({required this.lesson, required this.onAds});

  Color _typeColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (lesson.lessonType.toLowerCase()) {
      case 'лк':
        return scheme.primary;
      case 'лб':
        return scheme.tertiary;
      case 'пр':
        return scheme.secondary;
      default:
        return scheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _typeColor(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${lesson.pairNumber} пара',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${lesson.timeStart}–${lesson.timeEnd}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (lesson.lessonType.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              lesson.typeLabel,
                              style: TextStyle(
                                color: color,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lesson.subjectFull.isNotEmpty
                          ? lesson.subjectFull
                          : lesson.subjectShort,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (lesson.classroom.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.room_outlined, size: 16),
                          const SizedBox(width: 4),
                          Expanded(child: Text(lesson.classroom)),
                        ],
                      ),
                    ],
                    if (lesson.teacher.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.person_outline, size: 16),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              lesson.teacherFull.isNotEmpty
                                  ? lesson.teacherFull
                                  : lesson.teacher,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (lesson.hasAds) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ActionChip(
                          avatar: const Icon(Icons.campaign_outlined, size: 18),
                          label: const Text('Оголошення'),
                          onPressed: () => onAds(lesson),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
