# Розклад КНУ (Flutter)

Нативне Android-застосування для перегляду розкладу занять
[Криворізького національного університету](https://asu.knu.edu.ua/time-table/group)
без WebView.

<table align="center">
  <tr>
    <th align="center">
      <sup>:warning: WARNING :warning:</sup>
    </th>
  </tr>
  <tr>
    <td align="center">
      Програма була повністю написана за допомогою <a href="https://grok.com">Grok</a>
  </tr>
</table>

## Що вміє

- Можна закріпити кілька груп (факультет / курс / група) — без повторного вибору
- Основна група + швидке перемикання
- Розклад **по днях** і **списком**
- Перегляд оголошень до пар
- Темна / світла тема (системна)
- Працює з Android 8+ (у т.ч. сучасні версії, де офіційний APK МКР «застарілий»)

## Як зібрати

Потрібні: **Flutter 3.22+**, Android SDK / Android Studio.

```bash
git clone https://github.com/sasungeee/knu_schedule

cd knu_schedule
flutter build apk --release
```

APK: `build/app/outputs/flutter-apk/app-release.apk`.

## Технічні деталі

Сайт на системі **МКР (ПС-Розклад)**. Публічного JSON API немає, тому клієнт:

1. `GET /time-table/group` — CSRF + cookies
2. `POST /time-table/group?type=0` з полями `TimeTableForm[...]` — факультети → курси → групи → HTML-таблиця
3. `GET /time-table/show-ads?r1=&r2=` + заголовок `X-Requested-With: XMLHttpRequest` — оголошення

Парсинг HTML таблиці `#timeTable`.

## Структура

```
lib/
  main.dart
  models/models.dart
  services/knu_api.dart    # мережа + парсер
  services/storage.dart    # SharedPreferences (закріплені групи)
  screens/
    home_screen.dart
    picker_screen.dart
    schedule_screen.dart
```

## Обмеження

- Залежить від HTML-розмітки сайту МКР (при великих змінах парсер може потребувати оновлення)
- Потрібен інтернет для першого завантаження; локальний офлайн-кеш розкладу можна додати пізніше
