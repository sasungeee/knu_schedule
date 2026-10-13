import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
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
                'Анонс',
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

  List<DaySchedule> _daysForMonth(int year, int month) {
    final days = _schedule?.days ?? const <DaySchedule>[];
    return days.where((d) {
      final dt = _parseDate(d.date);
      return dt != null && dt.year == year && dt.month == month;
    }).toList();
  }

  Future<Uint8List> _buildMonthPdf(int year, int month) async {
    final g = widget.group;
    final filtered = _daysForMonth(year, month);
    final fontData =
        await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final fontBoldData =
        await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    final font = pw.Font.ttf(fontData);
    final fontBold = pw.Font.ttf(fontBoldData);

    final doc = pw.Document(
      title: 'Розклад ${g.name} — ${_monthLabel(DateTime(year, month))}',
      author: 'Розклад КНУ',
    );

    final theme = pw.ThemeData.withFont(base: font, bold: fontBold);

    doc.addPage(
      pw.MultiPage(
        theme: theme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 40),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Розклад занять',
              style: pw.TextStyle(font: fontBold, fontSize: 16),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              '${g.name}  ·  ${g.course} курс  ·  ${g.facultyName}',
              style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700),
            ),
            pw.Text(
              _monthLabel(DateTime(year, month)),
              style: pw.TextStyle(font: fontBold, fontSize: 12),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Оновлено: ${DateFormat('dd.MM.yyyy HH:mm').format(_schedule!.loadedAt)}',
              style: pw.TextStyle(font: font, fontSize: 8, color: PdfColors.grey600),
            ),
            pw.Text(
              'Стор. ${ctx.pageNumber} / ${ctx.pagesCount}',
              style: pw.TextStyle(font: font, fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (ctx) {
          if (filtered.isEmpty) {
            return [
              pw.Text(
                'Немає занять у цьому місяці.',
                style: pw.TextStyle(font: font, fontSize: 11),
              ),
            ];
          }

          final widgets = <pw.Widget>[];
          for (final d in filtered) {
            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 10),
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '${d.weekday}  ${d.date}',
                      style: pw.TextStyle(font: fontBold, fontSize: 11),
                    ),
                    pw.SizedBox(height: 4),
                    if (d.lessons.isEmpty)
                      pw.Text(
                        'Пар немає',
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 10,
                          color: PdfColors.grey600,
                        ),
                      )
                    else
                      ...d.lessons.map((l) {
                        final time = [
                          if (l.timeStart.isNotEmpty) l.timeStart,
                          if (l.timeEnd.isNotEmpty) l.timeEnd,
                        ].join('–');
                        final pair =
                            l.pairNumber > 0 ? '${l.pairNumber} пара' : '';
                        final head = [
                          if (pair.isNotEmpty) pair,
                          if (time.isNotEmpty) time,
                          if (l.lessonType.isNotEmpty) l.lessonType,
                        ].join('  ·  ');
                        final subj = l.subjectFull.isNotEmpty
                            ? l.subjectFull
                            : l.subjectShort;
                        return pw.Padding(
                          padding: const pw.EdgeInsets.only(top: 4, bottom: 2),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              if (head.isNotEmpty)
                                pw.Text(
                                  head,
                                  style: pw.TextStyle(
                                    font: fontBold,
                                    fontSize: 9,
                                    color: PdfColors.blueGrey800,
                                  ),
                                ),
                              pw.Text(
                                subj,
                                style: pw.TextStyle(font: font, fontSize: 10),
                              ),
                              if (l.classroom.isNotEmpty ||
                                  l.teacher.isNotEmpty)
                                pw.Text(
                                  [
                                    if (l.classroom.isNotEmpty)
                                      'ауд. ${l.classroom}',
                                    if (l.teacher.isNotEmpty)
                                      (l.teacherFull.isNotEmpty
                                          ? l.teacherFull
                                          : l.teacher),
                                  ].join('  ·  '),
                                  style: pw.TextStyle(
                                    font: font,
                                    fontSize: 9,
                                    color: PdfColors.grey700,
                                  ),
                                ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            );
          }
          return widgets;
        },
      ),
    );

    return doc.save();
  }

  Future<void> _downloadMonth() async {
    final schedule = _schedule;
    if (schedule == null || schedule.days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Спочатку завантажте розклад')),
      );
      return;
    }

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
    final initial = sorted.firstWhere(
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
                  'Завантажити розклад (PDF)',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sorted.length,
                  itemBuilder: (_, i) {
                    final m = sorted[i];
                    final selected =
                        m.year == initial.year && m.month == initial.month;
                    return ListTile(
                      leading: Icon(
                        selected
                            ? Icons.picture_as_pdf
                            : Icons.picture_as_pdf_outlined,
                      ),
                      title: Text(_monthLabel(m)),
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

    // Прогрес
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Формую PDF…'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final bytes = await _buildMonthPdf(chosen.year, chosen.month);
      if (!mounted) return;
      Navigator.of(context).pop(); // progress

      final g = widget.group;
      final safeName = g.name.replaceAll(RegExp(r'[^\wа-яА-ЯіІїЇєЄґҐ\-]+'), '_');
      final fileName =
          'rozklad_${safeName}_${chosen.year}_${chosen.month.toString().padLeft(2, '0')}.pdf';

      // На desktop (Linux/Windows/macOS) saveFile лише повертає шлях —
      // bytes треба записати самим. На Android/iOS bytes пише плагін.
      var path = await FilePicker.platform.saveFile(
        dialogTitle: 'Зберегти розклад',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: bytes,
      );

      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Збереження скасовано')),
        );
        return;
      }

      if (!path.toLowerCase().endsWith('.pdf')) {
        path = '$path.pdf';
      }

      // Завжди дописуємо файл (на Linux/Windows bytes ігноруються).
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Збережено:\n$path')),
      );
    } catch (e) {
      if (!mounted) return;
      // Закрити прогрес, якщо ще відкритий.
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Помилка PDF: $e')),
      );
    }
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
                          label: const Text('Анонс'),
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
