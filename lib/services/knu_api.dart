import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Клієнт до asu.knu.edu.ua (система МКР).
///
/// Сайт не дає публічного JSON API, тому працюємо через ті ж
/// form-POST / AJAX, що й веб-інтерфейс.
class KnuApi {
  static const baseUrl = 'https://asu.knu.edu.ua';
  static const userAgent =
      'KNUSchedule/1.0 (Android; Flutter; +https://github.com/local/knu_schedule)';

  final http.Client _client;
  final Map<String, String> _cookies = {};
  String? _csrf;

  KnuApi({http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        'Accept': 'text/html,application/xhtml+xml,application/json',
        'Accept-Language': 'uk-UA,uk;q=0.9,en;q=0.8',
        if (_cookies.isNotEmpty)
          'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      };

  void _storeCookies(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null) return;
    // Може бути кілька Set-Cookie через кому — спрощено
    for (final part in raw.split(',')) {
      final first = part.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq > 0) {
        _cookies[first.substring(0, eq)] = first.substring(eq + 1);
      }
    }
  }

  void _extractCsrf(String html) {
    final doc = html_parser.parse(html);
    final input = doc.querySelector('input[name="_csrf-frontend"]');
    if (input != null) {
      _csrf = input.attributes['value'];
      return;
    }
    final meta = doc.querySelector('meta[name="csrf-token"]');
    if (meta != null) {
      _csrf = meta.attributes['content'];
    }
  }

  Future<void> _ensureSession() async {
    if (_csrf != null && _cookies.isNotEmpty) return;
    final res = await _client.get(
      Uri.parse('$baseUrl/time-table/group'),
      headers: _headers,
    );
    _storeCookies(res);
    _extractCsrf(res.body);
    if (_csrf == null) {
      throw KnuApiException('Не вдалося отримати CSRF-токен');
    }
  }

  Future<http.Response> _postForm(Map<String, String> fields) async {
    await _ensureSession();
    final body = {
      '_csrf-frontend': _csrf!,
      ...fields,
    };
    final res = await _client.post(
      Uri.parse('$baseUrl/time-table/group?type=0'),
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': '$baseUrl/time-table/group',
      },
      body: body,
    );
    _storeCookies(res);
    _extractCsrf(res.body);
    if (res.statusCode >= 400) {
      throw KnuApiException('HTTP ${res.statusCode}');
    }
    return res;
  }

  /// Список факультетів.
  Future<List<Faculty>> getFaculties() async {
    await _ensureSession();
    final res = await _client.get(
      Uri.parse('$baseUrl/time-table/group'),
      headers: _headers,
    );
    _storeCookies(res);
    _extractCsrf(res.body);
    return _parseSelectOptions(res.body, 'timetableform-facultyid')
        .map((e) => Faculty(id: e.key, name: e.value))
        .toList();
  }

  /// Курси для факультету.
  Future<List<int>> getCourses(int facultyId) async {
    final res = await _postForm({
      'TimeTableForm[facultyId]': '$facultyId',
      'TimeTableForm[course]': '',
      'TimeTableForm[groupId]': '',
    });
    return _parseSelectOptions(res.body, 'timetableform-course')
        .map((e) => e.key)
        .toList();
  }

  /// Групи факультету + курсу.
  Future<List<Group>> getGroups({
    required int facultyId,
    required String facultyName,
    required int course,
  }) async {
    final res = await _postForm({
      'TimeTableForm[facultyId]': '$facultyId',
      'TimeTableForm[course]': '$course',
      'TimeTableForm[groupId]': '',
    });
    return _parseSelectOptions(res.body, 'timetableform-groupid')
        .map(
          (e) => Group(
            id: e.key,
            name: e.value,
            facultyId: facultyId,
            facultyName: facultyName,
            course: course,
          ),
        )
        .toList();
  }

  /// Розклад групи (табличний вигляд type=0).
  Future<ScheduleResult> getSchedule(Group group) async {
    // Повний submit (не лише AJAX-оновлення форми)
    await _ensureSession();
    final body = {
      '_csrf-frontend': _csrf!,
      'TimeTableForm[facultyId]': '${group.facultyId}',
      'TimeTableForm[course]': '${group.course}',
      'TimeTableForm[groupId]': '${group.id}',
    };
    final res = await _client.post(
      Uri.parse('$baseUrl/time-table/group?type=0'),
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': '$baseUrl/time-table/group',
      },
      body: body,
    );
    _storeCookies(res);
    _extractCsrf(res.body);
    if (res.statusCode >= 400) {
      throw KnuApiException('Не вдалося завантажити розклад (${res.statusCode})');
    }
    final days = _parseScheduleTable(res.body);
    // Повторне сортування на рівні API (на випадок дивного HTML)
    days.sort((a, b) {
      final da = _parseDdMmYyyy(a.date);
      final db = _parseDdMmYyyy(b.date);
      if (da == null || db == null) return a.date.compareTo(b.date);
      return da.compareTo(db);
    });
    return ScheduleResult(
      group: group,
      days: days,
      loadedAt: DateTime.now(),
    );
  }

  /// Текст оголошення до пари.
  Future<String> getAds({required int r1, required String r2}) async {
    final uri = Uri.parse('$baseUrl/time-table/show-ads').replace(
      queryParameters: {'r1': '$r1', 'r2': r2},
    );
    final res = await _client.get(
      uri,
      headers: {
        ..._headers,
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json',
      },
    );
    if (res.statusCode != 200) {
      throw KnuApiException('Оголошення недоступні (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final html = data['html'] as String? ?? '';
    return _stripHtml(html);
  }

  // --- parsers ---

  List<MapEntry<int, String>> _parseSelectOptions(String html, String selectId) {
    final doc = html_parser.parse(html);
    final select = doc.getElementById(selectId);
    if (select == null) return [];
    final result = <MapEntry<int, String>>[];
    for (final opt in select.querySelectorAll('option')) {
      final v = opt.attributes['value'] ?? '';
      if (v.isEmpty) continue;
      final id = int.tryParse(v);
      if (id == null) continue;
      final name = opt.text.trim();
      if (name.isEmpty) continue;
      result.add(MapEntry(id, name));
    }
    return result;
  }

  List<DaySchedule> _parseScheduleTable(String html) {
    final doc = html_parser.parse(html);
    final table = doc.getElementById('timeTable');
    if (table == null) return [];

    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) return [];

    // Перший рядок: weekday + дати
    final headerCells = rows.first.children;
    // [0] = "Пн"/порожньо, далі дати
    final dates = <String>[];
    final weekdays = <String>[];
    // У таблиці МКР: перша th — день тижня для рядка дат? Структура:
    // <th class="headday">Пн</th><th class="headdate">31.08.2026</th>...
    // Насправді для кожного дня тижня окремий блок рядків.
    // Парсимо простіше: збираємо всі headdate і відповідні пари.

    // Альтернативний підхід: пройти всі рядки з headcol (номер пари)
    // і клітинки lesson-*

    final byDate = <String, List<Lesson>>{};
    final dateOrder = <String>[];
    String currentWeekday = '';

    for (final row in rows) {
      final headDay = row.querySelector('th.headday');
      if (headDay != null && row.querySelectorAll('th.headdate').isNotEmpty) {
        currentWeekday = headDay.text.trim();
        for (final th in row.querySelectorAll('th.headdate')) {
          final d = th.text.trim();
          if (d.isEmpty) continue;
          if (!byDate.containsKey(d)) {
            byDate[d] = [];
            dateOrder.add(d);
          }
          // зберігаємо weekday у окремій мапі через замикання нижче
          _weekdayMap[d] = currentWeekday;
        }
        continue;
      }

      final headcol = row.querySelector('th.headcol');
      if (headcol == null) continue;

      final pairText = headcol.querySelector('span.lesson')?.text ?? '';
      final pairNumber =
          int.tryParse(RegExp(r'\d+').firstMatch(pairText)?.group(0) ?? '') ?? 0;
      final timeStart = headcol.querySelector('span.start')?.text.trim() ?? '';
      final timeEnd = headcol.querySelector('span.end')?.text.trim() ?? '';

      final cells = row.querySelectorAll('td');
      // cells відповідають датам поточного блоку headdate
      // Знаходимо дати з попереднього header-рядка цього блоку —
      // для простоти: беремо dateOrder з останнього заголовка.
      // Надійніше: у кожній клітинці data-content є дата.

      for (final td in cells) {
        final lessonDiv = td.querySelector('[class*="lesson-"]');
        if (lessonDiv == null) continue;

        final pop = lessonDiv.querySelector('[data-content]');
        final content = pop?.attributes['data-content'] ?? '';
        final title = pop?.attributes['title'] ?? '';

        // title: "14.09.2026 1 пара"
        final dateMatch = RegExp(r'(\d{2}\.\d{2}\.\d{4})').firstMatch(title);
        final date = dateMatch?.group(1) ?? '';
        if (date.isEmpty) continue;

        final adsBtn = lessonDiv.querySelector('a.btn-show-ads');
        final r1 = int.tryParse(adsBtn?.attributes['data-r1'] ?? '');
        final r2 = adsBtn?.attributes['data-r2'];

        final parsed = _parseLessonContent(
          content: content,
          shortHtml: lessonDiv,
          pairNumber: pairNumber,
          timeStart: timeStart,
          timeEnd: timeEnd,
          date: date,
          adsR1: r1,
          adsDate: r2,
        );

        byDate.putIfAbsent(date, () {
          dateOrder.add(date);
          return [];
        });
        byDate[date]!.add(parsed);
        if (!_weekdayMap.containsKey(date) && currentWeekday.isNotEmpty) {
          _weekdayMap[date] = currentWeekday;
        }
      }
    }

    // Сайт групує колонки за днем тижня (усі Пн, потім усі Вт...).
    // Для UI сортуємо хронологічно за датою.
    final result = <DaySchedule>[];
    final seen = <String>{};
    for (final d in dateOrder) {
      if (!seen.add(d)) continue;
      final lessons = List<Lesson>.from(byDate[d] ?? const []);
      lessons.sort((a, b) => a.pairNumber.compareTo(b.pairNumber));
      result.add(DaySchedule(
        date: d,
        weekday: _weekdayMap[d] ?? _weekdayFromDate(d),
        lessons: lessons,
      ));
    }
    result.sort((a, b) {
      final da = _parseDdMmYyyy(a.date);
      final db = _parseDdMmYyyy(b.date);
      if (da == null && db == null) return a.date.compareTo(b.date);
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
    _weekdayMap.clear();
    return result;
  }

  DateTime? _parseDdMmYyyy(String ddmmyyyy) {
    try {
      final p = ddmmyyyy.split('.');
      if (p.length != 3) return null;
      return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
    } catch (_) {
      return null;
    }
  }

  final Map<String, String> _weekdayMap = {};

  Lesson _parseLessonContent({
    required String content,
    required Element shortHtml,
    required int pairNumber,
    required String timeStart,
    required String timeEnd,
    required String date,
    int? adsR1,
    String? adsDate,
  }) {
    // content: "Основи інженерії...[Лк]<br>ауд. 1-232_[9]<br>ІПЗ-26<br>Стрюк ...<br>Додано: ..."
    final parts = content
        .replaceAllMapped(RegExp(r'<br\s*/?>', caseSensitive: false), (_) => '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    String subjectFull = parts.isNotEmpty ? parts[0] : '';
    String lessonType = '';
    final typeMatch = RegExp(r'\[([^\]]+)\]').firstMatch(subjectFull);
    if (typeMatch != null) {
      lessonType = typeMatch.group(1) ?? '';
      subjectFull = subjectFull.replaceAll(typeMatch.group(0)!, '').trim();
    }

    String classroom = '';
    String teacherFull = '';
    for (final p in parts.skip(1)) {
      if (p.toLowerCase().startsWith('ауд') || p.toLowerCase().contains('ауд.')) {
        classroom = p;
      } else if (p.startsWith('Додано')) {
        continue;
      } else if (!p.contains('-26') && !p.contains('-25') && teacherFull.isEmpty) {
        // груба евристика: не назва групи
        if (!RegExp(r'^[А-ЯІЇЄA-Z]{2,}-').hasMatch(p)) {
          teacherFull = p;
        }
      }
    }

    // short text from cell
    final shortText = shortHtml.text
        .replaceAll('Оголошення', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final subjectShort = shortText.isNotEmpty
        ? shortText.split(RegExp(r'\[')).first.trim()
        : subjectFull;

    final teacherShort = shortHtml.querySelector('i')?.text.trim() ?? teacherFull;

    return Lesson(
      pairNumber: pairNumber,
      timeStart: timeStart,
      timeEnd: timeEnd,
      date: date,
      subjectShort: subjectShort.isEmpty ? subjectFull : subjectShort,
      subjectFull: subjectFull.isEmpty ? subjectShort : subjectFull,
      lessonType: lessonType,
      classroom: classroom.replaceFirst(RegExp(r'^ауд\.?\s*', caseSensitive: false), ''),
      teacher: teacherShort,
      teacherFull: teacherFull.isEmpty ? teacherShort : teacherFull,
      adsR1: adsR1,
      adsDate: adsDate,
    );
  }

  String _weekdayFromDate(String ddmmyyyy) {
    try {
      final p = ddmmyyyy.split('.');
      final dt = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'];
      return names[dt.weekday - 1];
    } catch (_) {
      return '';
    }
  }

  String _stripHtml(String html) {
    final doc = html_parser.parse(html);
    // Зберігаємо посилання у вигляді "текст (url)"
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      final t = a.text.trim();
      a.replaceWith(Text(t.isEmpty ? href : '$t\n$href'));
    }
    final text = doc.body?.text ?? doc.documentElement?.text ?? html;
    return text
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  void dispose() => _client.close();
}

class KnuApiException implements Exception {
  final String message;
  KnuApiException(this.message);
  @override
  String toString() => message;
}
