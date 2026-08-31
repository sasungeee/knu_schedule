import 'package:flutter/material.dart';
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
      // Сайт віддає дні блоками Пн…Пн, Вт…Вт — сортуємо за датою
      final sortedDays = List<DaySchedule>.from(s.days)
        ..sort((a, b) {
          final da = _parseDate(a.date);
          final db = _parseDate(b.date);
          if (da == null || db == null) return a.date.compareTo(b.date);
          return da.compareTo(db);
        });
      final sorted = ScheduleResult(
        group: s.group,
        days: sortedDays,
        loadedAt: s.loadedAt,
      );
      final today = DateFormat('dd.MM.yyyy').format(DateTime.now());
      var idx = sorted.days.indexWhere((d) => d.date == today);
      if (idx < 0) idx = 0;
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
    if (lesson.adsR1 == null || lesson.adsDate == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final text = await widget.api.getAds(
        r1: lesson.adsR1!,
        r2: lesson.adsDate!,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // progress
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
                SelectableText(
                  text.isEmpty ? 'Немає тексту оголошення' : text,
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                // клікабельні URL
                ..._extractUrls(text).map(
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
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Помилка: $e')),
      );
    }
  }

  List<String> _extractUrls(String text) {
    final re = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
    return re.allMatches(text).map((m) => m.group(0)!).toSet().toList();
  }

  DateTime? _parseDate(String ddmmyyyy) {
    final cleaned = ddmmyyyy.replaceAll(RegExp(r'[^\d.]'), '');
    final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})$').firstMatch(cleaned);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(3)!),
      int.parse(m.group(2)!),
      int.parse(m.group(1)!),
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
              final dayNum = d.date.length >= 5 ? d.date.substring(0, 5) : d.date;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    '${d.weekday} $dayNum',
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
