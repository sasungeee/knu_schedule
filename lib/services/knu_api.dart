import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Клієнт до asu.knu.edu.ua (система МКР v3).
///
/// З осені 2026 інтерфейс повністю перероблений:
///   POST /time-table/get-faculties  {id: structureId}
///   POST /time-table/get-courses    {id: facultyId}
///   POST /time-table/get-groups     {id: courseId, facultyId: facultyId}
///   POST /time-table/get-schedule   {type: "group", id: groupId}
///
/// Відповіді select-ів — JSON-масив [{id, text}, ...].
/// Розклад — JSON {html: "..."} або {events: [...], startDate: "..."}.
class KnuApi {
  static const baseUrl = 'https://asu.knu.edu.ua';
  static const userAgent =
      'KNUSchedule/2.0 (Android; Flutter; +https://github.com/sasungeee/knu_schedule)';

  /// ID структури «Криворізький національний університет» (єдиний option на сторінці).
  static const defaultStructureId = 0;

  final http.Client _client;
  final Map<String, String> _cookies = {};
  String? _csrf;
  bool _loggedIn = false;

  String? _username;
  String? _password;

  KnuApi({http.Client? client}) : _client = client ?? http.Client();

  bool get isLoggedIn => _loggedIn;

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        'Accept': 'text/html,application/xhtml+xml,application/json',
        'Accept-Language': 'uk-UA,uk;q=0.9,en;q=0.8',
        if (_cookies.isNotEmpty)
          'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        if (_csrf != null) 'X-CSRF-Token': _csrf!,
      };

  Map<String, String> get _ajaxHeaders => {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'Referer': '$baseUrl/time-table/group',
        'Origin': baseUrl,
      };

  void _storeCookies(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final part in _splitSetCookie(raw)) {
      final first = part.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq > 0) {
        final name = first.substring(0, eq).trim();
        final value = first.substring(eq + 1).trim();
        if (name.isNotEmpty) _cookies[name] = value;
      }
    }
  }

  List<String> _splitSetCookie(String raw) {
    final result = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == ',') {
        final rest = raw.substring(i + 1).trimLeft();
        if (RegExp(r'^[A-Za-z0-9_-]+=').hasMatch(rest)) {
          final s = buffer.toString().trim();
          if (s.isNotEmpty) result.add(s);
          buffer.clear();
          continue;
        }
      }
      buffer.write(c);
    }
    final s = buffer.toString().trim();
    if (s.isNotEmpty) result.add(s);
    return result;
  }

  void _extractCsrf(String html) {
    final doc = html_parser.parse(html);
    final meta = doc.querySelector('meta[name="csrf-token"]');
    if (meta != null) {
      _csrf = meta.attributes['content'];
      return;
    }
    final input = doc.querySelector('input[name="_csrf-frontend"]');
    if (input != null) {
      _csrf = input.attributes['value'];
    }
  }

  bool _isLoginPage(String html) {
    final lower = html.toLowerCase();
    return lower.contains('id="login-form"') ||
        lower.contains('loginform-username') ||
        (lower.contains('увійдіть') && lower.contains('login-form'));
  }

  void setCredentials(String username, String password) {
    _username = username.trim();
    _password = password;
  }

  void clearCredentials() {
    _username = null;
    _password = null;
    _loggedIn = false;
    _cookies.clear();
    _csrf = null;
  }

  Future<bool> login(String username, String password) async {
    username = username.trim();
    if (username.isEmpty || password.isEmpty) {
      throw KnuApiException('Введіть логін і пароль');
    }

    final getRes = await _client.get(
      Uri.parse('$baseUrl/login'),
      headers: {
        'User-Agent': userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'uk-UA,uk;q=0.9,en;q=0.8',
      },
    );
    _storeCookies(getRes);
    _extractCsrf(getRes.body);
    if (_csrf == null) {
      throw KnuApiException('Не вдалося отримати CSRF-токен зі сторінки входу');
    }

    final body = {
      '_csrf-frontend': _csrf!,
      'LoginForm[username]': username,
      'LoginForm[password]': password,
      'LoginForm[rememberMe]': '1',
      'login-button': '',
    };

    final postRes = await _client.post(
      Uri.parse('$baseUrl/login'),
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': '$baseUrl/login',
        'Origin': baseUrl,
      },
      body: body,
    );
    _storeCookies(postRes);
    _extractCsrf(postRes.body);

    if (_isLoginPage(postRes.body)) {
      final doc = html_parser.parse(postRes.body);
      final err =
          doc.querySelector('.invalid-feedback, .alert-danger, .help-block');
      final msg = err?.text.trim();
      if (msg != null && msg.isNotEmpty) {
        throw KnuApiException(msg);
      }
      throw KnuApiException('Невірний логін або пароль');
    }

    // Підтверджуємо доступ до розкладу і підхоплюємо свіжий CSRF.
    final check = await _client.get(
      Uri.parse('$baseUrl/time-table/group'),
      headers: _headers,
    );
    _storeCookies(check);
    _extractCsrf(check.body);

    if (_isLoginPage(check.body)) {
      throw KnuApiException('Вхід виконано, але доступ до розкладу заборонено');
    }

    _username = username;
    _password = password;
    _loggedIn = true;
    return true;
  }

  Future<void> logout() async {
    try {
      await _client.get(Uri.parse('$baseUrl/logout'), headers: _headers);
    } catch (_) {}
    clearCredentials();
  }

  Future<void> _ensureSession() async {
    if (_loggedIn && _csrf != null && _cookies.isNotEmpty) return;
    if (_username != null && _password != null && _username!.isNotEmpty) {
      await login(_username!, _password!);
      return;
    }
    throw KnuAuthException('Потрібен вхід до asu.knu.edu.ua');
  }

  /// POST x-www-form-urlencoded, повертає body (з авто-релогіном при 401/login-page).
  Future<http.Response> _postAjax(
    String path,
    Map<String, String> fields, {
    bool expectJson = true,
  }) async {
    await _ensureSession();

    Future<http.Response> doPost() {
      final body = <String, String>{
        if (_csrf != null) '_csrf-frontend': _csrf!,
        ...fields,
      };
      return _client.post(
        Uri.parse('$baseUrl$path'),
        headers: _ajaxHeaders,
        body: body,
      );
    }

    var res = await doPost();
    _storeCookies(res);
    // Інколи CSRF оновлюється в HTML-відповіді (рідко для JSON).
    if (res.body.contains('csrf-token') || res.body.contains('_csrf-frontend')) {
      _extractCsrf(res.body);
    }

    if (_isLoginPage(res.body) || res.statusCode == 401 || res.statusCode == 403) {
      _loggedIn = false;
      if (_username != null && _password != null) {
        await login(_username!, _password!);
        res = await doPost();
        _storeCookies(res);
        if (_isLoginPage(res.body) || res.statusCode >= 400) {
          throw KnuAuthException('Сесія закінчилась. Увійдіть знову.');
        }
      } else {
        throw KnuAuthException('Сесія закінчилась. Увійдіть знову.');
      }
    }

    if (res.statusCode >= 400) {
      throw KnuApiException('HTTP ${res.statusCode} на $path');
    }
    return res;
  }

  Future<List<MapEntry<int, String>>> _fetchSelectOptions(
    String path,
    Map<String, String> fields,
  ) async {
    final res = await _postAjax(path, fields);
    final decoded = jsonDecode(res.body);
    if (decoded is! List) {
      throw KnuApiException('Неочікувана відповідь $path (очікувався масив)');
    }
    final result = <MapEntry<int, String>>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final idRaw = item['id'];
      final text = (item['text'] ?? item['name'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      final id = idRaw is int
          ? idRaw
          : int.tryParse(idRaw?.toString() ?? '');
      if (id == null) continue;
      result.add(MapEntry(id, text));
    }
    return result;
  }

  /// Список факультетів (structureId за замовчуванням = 0).
  Future<List<Faculty>> getFaculties({int structureId = defaultStructureId}) async {
    final opts = await _fetchSelectOptions(
      '/time-table/get-faculties',
      {'id': '$structureId'},
    );
    return opts.map((e) => Faculty(id: e.key, name: e.value)).toList();
  }

  /// Список курсів для факультету.
  Future<List<int>> getCourses(int facultyId) async {
    final opts = await _fetchSelectOptions(
      '/time-table/get-courses',
      {'id': '$facultyId'},
    );
    return opts.map((e) => e.key).toList();
  }

  /// Список груп для факультету + курсу.
  Future<List<Group>> getGroups({
    required int facultyId,
    required String facultyName,
    required int course,
  }) async {
    final opts = await _fetchSelectOptions(
      '/time-table/get-groups',
      {
        'id': '$course',
        'facultyId': '$facultyId',
      },
    );
    return opts
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

  /// Завантажити розклад групи.
  Future<ScheduleResult> getSchedule(Group group) async {
    final res = await _postAjax(
      '/time-table/get-schedule',
      {
        'type': 'group',
        'id': '${group.id}',
      },
    );

    final decoded = jsonDecode(res.body);
    String html = '';
    if (decoded is Map) {
      html = (decoded['html'] as String?) ?? '';
      // Calendar-view fallback: якщо є events — парсимо їх.
      if (html.isEmpty && decoded['events'] is List) {
        final days = _parseEventsJson(decoded['events'] as List);
        return ScheduleResult(
          group: group,
          days: days,
          loadedAt: DateTime.now(),
        );
      }
    } else if (decoded is String) {
      html = decoded;
    }

    if (html.isEmpty) {
      return ScheduleResult(
        group: group,
        days: const [],
        loadedAt: DateTime.now(),
      );
    }

    final days = _sortDays(_parseScheduleHtml(html));

    return ScheduleResult(
      group: group,
      days: days,
      loadedAt: DateTime.now(),
    );
  }

  /// Оголошення до пари (стара точка, якщо ще жива).
  Future<String> getAds({required int r1, required String r2}) async {
    await _ensureSession();
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
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final html = data['html'] as String? ?? '';
      return _stripHtml(html);
    } catch (_) {
      return _stripHtml(res.body);
    }
  }

  // ---------------------------------------------------------------------------
  // Парсери
  // ---------------------------------------------------------------------------

  /// Парсинг HTML-таблиці / карток розкладу (нова розмітка МКР 3.x).
  ///
  /// Шукаємо будь-які елементи з data-discipline / data-date / data-pair-number
  /// (саме їх JS підставляє в модалку деталей пари).
  List<DaySchedule> _parseScheduleHtml(String html) {
    final doc = html_parser.parse(html);
    final byDate = <String, List<Lesson>>{};

    // 1) Картки / клітинки з data-атрибутами (основний шлях).
    final cards = doc.querySelectorAll(
      '[data-discipline], [data-pair-number], .schedule-table-td, '
      '.fc-lesson-card, .schedule-card-stacked, [data-bs-toggle="modal"]',
    );

    for (final el in cards) {
      final lesson = _lessonFromDataAttrs(el);
      if (lesson == null) continue;
      byDate.putIfAbsent(lesson.date, () => []);
      final list = byDate[lesson.date]!;
      final dup = list.any(
        (l) =>
            l.pairNumber == lesson.pairNumber &&
            l.subjectFull == lesson.subjectFull &&
            l.timeStart == lesson.timeStart,
      );
      if (!dup) list.add(lesson);
    }

    // 2) Fallback: стара таблиця #timeTable (якщо раптом повернуть).
    if (byDate.isEmpty) {
      final legacy = _parseLegacyTimeTable(doc);
      if (legacy.isNotEmpty) return _sortDays(legacy);
    }

    // 3) Fallback: list-view рядки.
    if (byDate.isEmpty) {
      for (final row in doc.querySelectorAll(
        '.schedule-list-item, .list-group-item, tr[data-date]',
      )) {
        final lesson = _lessonFromDataAttrs(row) ?? _lessonFromTextBlock(row);
        if (lesson == null) continue;
        byDate.putIfAbsent(lesson.date, () => []);
        byDate[lesson.date]!.add(lesson);
      }
    }

    // Глобальний прохід: кнопки анонсів, що могли лишитись поза карткою.
    _attachOrphanAnnouncements(doc, byDate);

    final result = <DaySchedule>[];
    for (final entry in byDate.entries) {
      final lessons = List<Lesson>.from(entry.value)
        ..sort((a, b) => a.pairNumber.compareTo(b.pairNumber));
      result.add(DaySchedule(
        date: entry.key,
        weekday: _weekdayFromDate(entry.key),
        lessons: lessons,
      ));
    }
    return _sortDays(result);
  }

  /// Якщо кнопка анонсу стоїть поруч з парою — прив'язуємо текст до Lesson.
  void _attachOrphanAnnouncements(
    Document doc,
    Map<String, List<Lesson>> byDate,
  ) {
    final buttons = doc.querySelectorAll(
      '[data-announcement], [data-ads], [data-announce], '
      '[data-bs-target="#announcementTextModal"], '
      '[data-bs-target*="announcement"]',
    );
    for (final btn in buttons) {
      var text = (btn.attributes['data-announcement'] ??
              btn.attributes['data-ads'] ??
              btn.attributes['data-announce'] ??
              '')
          .trim();
      if (text.isEmpty) {
        Element? p = btn.parent;
        for (var i = 0; i < 3 && p != null; i++) {
          text = (p.attributes['data-announcement'] ??
                  p.attributes['data-ads'] ??
                  '')
              .trim();
          if (text.isNotEmpty) break;
          p = p.parent;
        }
      }
      if (text.isEmpty) continue;

      String date = '';
      int pair = 0;

      void readAttrs(Element? e) {
        if (e == null) return;
        final d = e.attributes['data-date'];
        if (d != null && d.trim().isNotEmpty) date = d.trim();
        final pr =
            e.attributes['data-pair-number'] ?? e.attributes['data-pair'];
        if (pr != null) pair = int.tryParse(pr) ?? pair;
      }

      Element? scope = btn;
      for (var i = 0; i < 10 && scope != null; i++) {
        readAttrs(scope);
        for (final child in scope.children) {
          readAttrs(child);
          for (final grand in child.children) {
            readAttrs(grand);
          }
        }
        if (date.isNotEmpty) break;
        scope = scope.parent;
      }

      if (date.isEmpty) {
        final blob =
            '${btn.attributes['title'] ?? ''} ${btn.parent?.text ?? ''}';
        final m = RegExp(r'(\d{1,2}\.\d{1,2}\.\d{4})').firstMatch(blob) ??
            RegExp(
              r'(\d{1,2}\s+[а-яіїєґА-ЯІЇЄҐ]+(?:\s+\d{4})?)',
              unicode: true,
            ).firstMatch(blob);
        if (m != null) date = m.group(1)!;
      }

      void applyTo(List<Lesson> list) {
        for (var i = 0; i < list.length; i++) {
          final l = list[i];
          if (pair > 0 && l.pairNumber != pair) continue;
          if (l.hasAds && (l.adsDate?.trim().isNotEmpty ?? false)) continue;
          list[i] = Lesson(
            pairNumber: l.pairNumber,
            timeStart: l.timeStart,
            timeEnd: l.timeEnd,
            date: l.date,
            subjectShort: l.subjectShort,
            subjectFull: l.subjectFull,
            lessonType: l.lessonType,
            classroom: l.classroom,
            teacher: l.teacher,
            teacherFull: l.teacherFull,
            adsR1: 1,
            adsDate: text,
          );
          break;
        }
      }

      if (date.isEmpty) {
        if (byDate.length == 1) {
          applyTo(byDate.values.first);
        } else {
          // Вішаємо на всі дні з цією парою (краще, ніж втратити анонс).
          for (final list in byDate.values) {
            applyTo(list);
          }
        }
        continue;
      }

      final norm = _normalizeDate(date);
      final list = byDate[norm] ?? byDate[date];
      if (list != null) {
        applyTo(list);
      } else {
        for (final entry in byDate.values) {
          applyTo(entry);
        }
      }
    }
  }

  /// Завжди сортуємо дні за реальною датою (не рядком).
  List<DaySchedule> _sortDays(List<DaySchedule> days) {
    days.sort((a, b) {
      final da = _parseAnyDate(a.date);
      final db = _parseAnyDate(b.date);
      if (da != null && db != null) return da.compareTo(db);
      if (da != null) return -1;
      if (db != null) return 1;
      return a.date.compareTo(b.date);
    });
    return days;
  }

  /// Нормалізує будь-який формат дати → dd.MM.yyyy.
  String _normalizeDate(String raw) {
    final dt = _parseAnyDate(raw);
    if (dt == null) {
      final m = RegExp(r'(\d{2})\.(\d{2})\.(\d{4})').firstMatch(raw);
      if (m != null) return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
      return raw.trim();
    }
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year}';
  }

  DateTime? _parseAnyDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // dd.MM.yyyy або d.M.yyyy
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

    // yyyy-MM-dd (ISO)
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
      // «листопада» перед «липня»!
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
        try {
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
        } catch (_) {}
      }
    }

    return DateTime.tryParse(s);
  }

  Lesson? _lessonFromDataAttrs(Element el) {
    // Атрибути можуть бути на самому елементі або на нащадку/предку.
    String attr(String name) {
      final v = el.attributes[name];
      if (v != null && v.trim().isNotEmpty) return v.trim();
      final child = el.querySelector('[$name]');
      if (child != null) {
        final cv = child.attributes[name];
        if (cv != null && cv.trim().isNotEmpty) return cv.trim();
      }
      // Піднятись до 3 рівнів вгору (картка часто обгортка).
      Element? p = el.parent;
      for (var i = 0; i < 3 && p != null; i++) {
        final pv = p.attributes[name];
        if (pv != null && pv.trim().isNotEmpty) return pv.trim();
        p = p.parent;
      }
      return '';
    }

    final discipline = attr('data-discipline').isNotEmpty
        ? attr('data-discipline')
        : attr('data-subject');
    final rawDate = attr('data-date');
    if (discipline.isEmpty && rawDate.isEmpty) {
      final child = el.querySelector('[data-discipline], [data-date]');
      if (child != null && child != el) return _lessonFromDataAttrs(child);
      return null;
    }
    if (rawDate.isEmpty) return null;

    final date = _normalizeDate(rawDate);
    final pairNumber = int.tryParse(attr('data-pair-number').isNotEmpty
            ? attr('data-pair-number')
            : (attr('data-pair').isNotEmpty
                ? attr('data-pair')
                : attr('data-number'))) ??
        0;
    final timeStart = attr('data-start');
    final timeEnd = attr('data-end');
    final lessonType = attr('data-type');
    final classroom = (attr('data-classroom').isNotEmpty
            ? attr('data-classroom')
            : attr('data-room'))
        .replaceFirst(RegExp(r'^ауд\.?\s*', caseSensitive: false), '');
    final teacher = attr('data-teacher');
    final topic = attr('data-topic');

    String subjectFull = discipline;
    if (topic.isNotEmpty) subjectFull = '$discipline. $topic';

    final shortText = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final subjectShort = shortText.isNotEmpty
        ? shortText.split(RegExp(r'\[')).first.trim()
        : discipline;

    // Оголошення / анонс — шукаємо агресивно в піддереві картки.
    final adsInfo = _extractAds(el);
    String adsRaw = adsInfo.text;
    final adsR1 = adsInfo.r1;
    final adsR2 = adsInfo.r2;

    if (adsR1 != null && adsRaw.isEmpty) {
      // Старий API show-ads за кодами.
      return Lesson(
        pairNumber: pairNumber,
        timeStart: timeStart,
        timeEnd: timeEnd,
        date: date,
        subjectShort: subjectShort.isEmpty ? discipline : subjectShort,
        subjectFull: subjectFull.isEmpty ? subjectShort : subjectFull,
        lessonType: lessonType,
        classroom: classroom,
        teacher: teacher,
        teacherFull: teacher,
        adsR1: adsR1,
        adsDate: adsR2,
      );
    }

    final hasAds = adsRaw.trim().isNotEmpty || adsInfo.flagOnly;

    return Lesson(
      pairNumber: pairNumber,
      timeStart: timeStart,
      timeEnd: timeEnd,
      date: date,
      subjectShort: subjectShort.isEmpty ? discipline : subjectShort,
      subjectFull: subjectFull.isEmpty ? subjectShort : subjectFull,
      lessonType: lessonType,
      classroom: classroom,
      teacher: teacher,
      teacherFull: teacher,
      adsR1: hasAds ? 1 : null,
      adsDate: adsRaw.trim().isNotEmpty
          ? adsRaw
          : (adsInfo.flagOnly ? ' ' : null),
    );
  }

  /// Результат пошуку оголошення в HTML-картці.
  ({String text, int? r1, String? r2, bool flagOnly}) _extractAds(Element el) {
    String text = '';
    int? r1;
    String? r2;
    var flagOnly = false;

    // 1) Прямі атрибути на елементі / батьках.
    for (final name in ['data-announcement', 'data-ads', 'data-announce']) {
      final v = el.attributes[name];
      if (v != null && v.trim().isNotEmpty) {
        text = v.trim();
        break;
      }
    }

    // 2) Будь-який нащадок з data-announcement / модалкою анонсу.
    final candidates = el.querySelectorAll(
      '[data-announcement], [data-ads], [data-announce], '
      '[data-bs-target="#announcementTextModal"], '
      '[data-bs-target="#announcementTextModal"] *, '
      '.btn-show-ads, a[href*="show-ads"], '
      'button[data-announcement], a[data-announcement], '
      '.bi-megaphone, .bi-megaphone-fill, .fa-bullhorn, '
      '.schedule-lesson-buttons-group-table button, '
      '.fc-lesson-buttons button, .fc-lesson-buttons a',
    );

    for (final btn in candidates) {
      // Піднятись до елемента з атрибутом, якщо клікнули на іконку всередині.
      Element? node = btn;
      for (var i = 0; i < 4 && node != null; i++) {
        final a = node.attributes['data-announcement'] ??
            node.attributes['data-ads'] ??
            node.attributes['data-announce'];
        if (a != null && a.trim().isNotEmpty) {
          if (text.isEmpty) text = a.trim();
          break;
        }
        final rr1 = int.tryParse(node.attributes['data-r1'] ?? '');
        if (rr1 != null) {
          r1 ??= rr1;
          r2 ??= node.attributes['data-r2'];
        }
        // data-bs-target на кнопці анонсу без тексту — все одно кнопка.
        final target = node.attributes['data-bs-target'] ?? '';
        if (target.contains('announcement')) flagOnly = true;
        node = node.parent;
      }

      final cls = btn.className.toLowerCase();
      if (cls.contains('megaphone') ||
          cls.contains('bullhorn') ||
          cls.contains('btn-show-ads')) {
        flagOnly = true;
      }
      final label = btn.text.trim().toLowerCase();
      if (label.contains('оголошен') ||
          label.contains('анонс') ||
          label.contains('announcement')) {
        flagOnly = true;
      }
    }

    // 3) title / aria-label з текстом оголошення.
    if (text.isEmpty) {
      for (final n in el.querySelectorAll('[title], [aria-label]')) {
        final t = (n.attributes['title'] ?? n.attributes['aria-label'] ?? '')
            .trim();
        if (t.length > 15 &&
            (t.toLowerCase().contains('http') ||
                t.contains(' ') && t.length > 30)) {
          // Ймовірно текст анонсу в title.
          if (n.attributes.containsKey('data-announcement') ||
              (n.attributes['data-bs-target'] ?? '').contains('announcement')) {
            text = t;
            break;
          }
        }
      }
    }

    return (text: text, r1: r1, r2: r2, flagOnly: flagOnly || text.isNotEmpty);
  }

  Lesson? _lessonFromTextBlock(Element el) {
    final text = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    final dateMatch = RegExp(r'(\d{2}\.\d{2}\.\d{4})').firstMatch(text);
    if (dateMatch == null) return null;
    final date = dateMatch.group(1)!;
    final pairMatch = RegExp(r'(?:пара|pair)\s*[№#]?\s*(\d+)', caseSensitive: false)
        .firstMatch(text);
    final pairNumber = int.tryParse(pairMatch?.group(1) ?? '') ?? 0;
    final timeMatch =
        RegExp(r'(\d{1,2}:\d{2})\s*[-–—]\s*(\d{1,2}:\d{2})').firstMatch(text);
    return Lesson(
      pairNumber: pairNumber,
      timeStart: timeMatch?.group(1) ?? '',
      timeEnd: timeMatch?.group(2) ?? '',
      date: date,
      subjectShort: text.length > 80 ? '${text.substring(0, 77)}…' : text,
      subjectFull: text,
      lessonType: '',
      classroom: '',
      teacher: '',
      teacherFull: '',
    );
  }

  /// FullCalendar events JSON (view «Тиждень» / «Місяць»).
  List<DaySchedule> _parseEventsJson(List events) {
    final byDate = <String, List<Lesson>>{};
    final dateOrder = <String>[];

    for (final raw in events) {
      if (raw is! Map) continue;
      final title = (raw['title'] ?? '').toString().trim();
      final start = (raw['start'] ?? '').toString();
      final end = (raw['end'] ?? '').toString();
      final props = raw['extendedProps'] is Map
          ? Map<String, dynamic>.from(raw['extendedProps'] as Map)
          : <String, dynamic>{};

      DateTime? startDt;
      try {
        startDt = DateTime.tryParse(start);
      } catch (_) {}
      if (startDt == null && start.contains('.')) {
        startDt = _parseDdMmYyyy(start.split(' ').first);
      }
      if (startDt == null) continue;

      final date = _normalizeDate(
        '${startDt.day.toString().padLeft(2, '0')}.'
        '${startDt.month.toString().padLeft(2, '0')}.'
        '${startDt.year}',
      );
      final timeStart =
          '${startDt.hour.toString().padLeft(2, '0')}:${startDt.minute.toString().padLeft(2, '0')}';

      String timeEnd = '';
      final endDt = DateTime.tryParse(end);
      if (endDt != null) {
        timeEnd =
            '${endDt.hour.toString().padLeft(2, '0')}:${endDt.minute.toString().padLeft(2, '0')}';
      }

      final pairNumber = int.tryParse(
            (props['pairNumber'] ?? props['pair'] ?? raw['pairNumber'] ?? '')
                .toString(),
          ) ??
          0;
      final lessonType =
          (props['type'] ?? props['lessonType'] ?? '').toString();
      final classroom =
          (props['classroom'] ?? props['room'] ?? '').toString();
      final teacher = (props['teacher'] ?? '').toString();
      final discipline =
          (props['discipline'] ?? props['subject'] ?? title).toString();

      final lesson = Lesson(
        pairNumber: pairNumber,
        timeStart: timeStart,
        timeEnd: timeEnd,
        date: date,
        subjectShort: discipline,
        subjectFull: title.isNotEmpty ? title : discipline,
        lessonType: lessonType,
        classroom: classroom,
        teacher: teacher,
        teacherFull: teacher,
      );

      byDate.putIfAbsent(date, () {
        dateOrder.add(date);
        return [];
      });
      byDate[date]!.add(lesson);
    }

    final result = <DaySchedule>[];
    for (final d in dateOrder) {
      final lessons = List<Lesson>.from(byDate[d] ?? const []);
      lessons.sort((a, b) => a.pairNumber.compareTo(b.pairNumber));
      result.add(DaySchedule(
        date: d,
        weekday: _weekdayFromDate(d),
        lessons: lessons,
      ));
    }
    return result;
  }

  /// Старий парсер #timeTable (на випадок відкату).
  List<DaySchedule> _parseLegacyTimeTable(Document doc) {
    final table = doc.getElementById('timeTable');
    if (table == null) return [];

    final byDate = <String, List<Lesson>>{};
    final dateOrder = <String>[];
    final weekdayMap = <String, String>{};
    String currentWeekday = '';

    for (final row in table.querySelectorAll('tr')) {
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
          weekdayMap[d] = currentWeekday;
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

      for (final td in row.querySelectorAll('td')) {
        final lessonDiv = td.querySelector('[class*="lesson-"]');
        if (lessonDiv == null) continue;

        final pop = lessonDiv.querySelector('[data-content]');
        final content = pop?.attributes['data-content'] ?? '';
        final title = pop?.attributes['title'] ?? '';
        final dateMatch = RegExp(r'(\d{2}\.\d{2}\.\d{4})').firstMatch(title);
        final date = dateMatch?.group(1) ?? '';
        if (date.isEmpty) continue;

        final adsBtn = lessonDiv.querySelector('a.btn-show-ads');
        final r1 = int.tryParse(adsBtn?.attributes['data-r1'] ?? '');
        final r2 = adsBtn?.attributes['data-r2'];

        final parts = content
            .replaceAllMapped(
                RegExp(r'<br\s*/?>', caseSensitive: false), (_) => '\n')
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
          if (p.toLowerCase().startsWith('ауд') ||
              p.toLowerCase().contains('ауд.')) {
            classroom = p;
          } else if (!p.startsWith('Додано') &&
              teacherFull.isEmpty &&
              !RegExp(r'^[А-ЯІЇЄA-Z]{2,}-').hasMatch(p)) {
            teacherFull = p;
          }
        }

        final shortText = lessonDiv.text
            .replaceAll('Оголошення', '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final subjectShort = shortText.isNotEmpty
            ? shortText.split(RegExp(r'\[')).first.trim()
            : subjectFull;
        final teacherShort =
            lessonDiv.querySelector('i')?.text.trim() ?? teacherFull;

        final lesson = Lesson(
          pairNumber: pairNumber,
          timeStart: timeStart,
          timeEnd: timeEnd,
          date: date,
          subjectShort: subjectShort.isEmpty ? subjectFull : subjectShort,
          subjectFull: subjectFull.isEmpty ? subjectShort : subjectFull,
          lessonType: lessonType,
          classroom: classroom.replaceFirst(
            RegExp(r'^ауд\.?\s*', caseSensitive: false),
            '',
          ),
          teacher: teacherShort,
          teacherFull: teacherFull.isEmpty ? teacherShort : teacherFull,
          adsR1: r1,
          adsDate: r2,
        );

        byDate.putIfAbsent(date, () {
          dateOrder.add(date);
          return [];
        });
        byDate[date]!.add(lesson);
        weekdayMap.putIfAbsent(date, () => currentWeekday);
      }
    }

    final result = <DaySchedule>[];
    final seen = <String>{};
    for (final d in dateOrder) {
      if (!seen.add(d)) continue;
      final lessons = List<Lesson>.from(byDate[d] ?? const []);
      lessons.sort((a, b) => a.pairNumber.compareTo(b.pairNumber));
      result.add(DaySchedule(
        date: d,
        weekday: weekdayMap[d] ?? _weekdayFromDate(d),
        lessons: lessons,
      ));
    }
    return result;
  }

  DateTime? _parseDdMmYyyy(String ddmmyyyy) => _parseAnyDate(ddmmyyyy);

  String _weekdayFromDate(String ddmmyyyy) {
    final dt = _parseAnyDate(ddmmyyyy);
    if (dt == null) return '';
    const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'];
    return names[dt.weekday - 1];
  }

  /// HTML → текст без дублювання URL (якщо текст посилання == href — один раз).
  String _stripHtml(String html) {
    final doc = html_parser.parse(html);
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = (a.attributes['href'] ?? '').trim();
      final t = a.text.trim();
      if (t.isEmpty) {
        a.replaceWith(Text(href));
      } else if (t == href || href.contains(t) || t.contains(href)) {
        a.replaceWith(Text(t));
      } else {
        a.replaceWith(Text('$t ($href)'));
      }
    }
    final text = doc.body?.text ?? doc.documentElement?.text ?? html;
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  void dispose() => _client.close();
}

class KnuApiException implements Exception {
  final String message;
  KnuApiException(this.message);
  @override
  String toString() => message;
}

class KnuAuthException extends KnuApiException {
  KnuAuthException(super.message);
}
