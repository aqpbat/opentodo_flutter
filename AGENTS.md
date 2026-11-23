# Инструкции для AI-агентов (OpenTodo Flutter)

Этот репозиторий — нативный Flutter-клиент для сервера OpenTodo. Задачи выполняет
другой агент по плану **[PLAN.md](PLAN.md)**; этот файл — контекст и правила, которые
нужно прочитать перед любой задачей. Описание проекта: [README.md](README.md).

## Контекст и пути

| Что | Где |
| --- | --- |
| Этот проект | `.` (корень репозитория) |
| Upstream OpenTodo (READ-ONLY, источник контрактов) | `../OpenTodo` (соседняя директория) |
| Рабочий сервер | Railway (адрес — в Railway dashboard, в репозиторий не коммитится) |
| План задач | `PLAN.md` (задачи M1.1 … M6.x, критерии приёмки, зависимости) |

**Upstream-репозиторий не изменять никогда.** Оттуда только читают контракты и копируют
векторы (`cp`, без правок). Сервер на Railway не модифицировать и не переразворачивать
без явной просьбы пользователя.

## Команды

Вывод команд в этом проекте сжимается rtk (см. `CLAUDE.md` и `.rtk/filters.toml`).
Считай сжатый вывод полным результатом; команды запускай как обычно, связанные —
одним вызовом. Полный вывод без фильтра: `rtk bypass <cmd>` — только когда
сжатый результат непригоден (пустой при ожидаемом выводе, противоречит коду
возврата или искажён).

```sh
flutter pub get                 # зависимости
flutter test                    # все тесты (чистый Dart, устройства не нужны)
flutter test test/e2ee_test.dart  # один файл
dart analyze                    # должно быть без error/warning (info допустимы временно)
node tool/sync_schema.mjs ~/Projects/OpenTodo   # регенерация lib/core/schema_generated.dart
flutter run                     # запуск на устройстве
```

Тесты используют `flutter_test`, но ядро — чистый Dart без Flutter-зависимостей:
всё в `lib/core/` и `lib/data/` должно оставаться тестируемым без устройства.
SQLite в тестах — через `sqflite_common_ffi` (уже в dev-зависимостях).

## Ненегоцируемые правила

1. **Совместимость доказывается векторами.** Любая портированная логика (recurrence,
   inbox, фильтры, даты, urgency…) проверяется общими векторами upstream
   (`web/src/lib/*.vectors.json` → копия в `test/vectors/`, без изменений). Нет векторов —
   сверять поведение с исходным TS/Go построчно и фиксировать эталоны в тестах.
2. **Все записи данных — через ops.** Никаких прямых REST-записей задач/проектов
   в обход op-log (кроме auth, key record и других не-sync маршрутов). Локальная
   правка = оптимистичное применение + outbox + обмен.
3. **Схема полей — генерируется.** `lib/core/schema_generated.dart` не править руками;
   менять только `tool/sync_schema.mjs` и регенерировать. Источник:
   `web/src/generated/opSchema.ts` (OP_DEFAULTS, OP_CONTENT_FIELDS).
4. **Заметки-документы не трогать.** Поля `notes_doc` и `appends.*` клиент MVP не пишет
   и не сливает (Yjs). `description` пишется только у сущностей без документа
   (проверять `notes_doc == ''`), иначе можно потерять чужой rich-text.
5. **Секреты не коммитить.** Токены, setup token сервера, passphrase, DEK — только
   в secure storage устройства. В тестах — фиктивные значения из векторов.
6. **Зависимости минимальны.** Каждая новая — с обоснованием в PR/коммите.
   Сейчас: pointycastle (крипто), crypto (sha256), http, sqflite, path_provider,
   flutter_secure_storage, unorm_dart (NFC). Material UI из шаблона (`material_ui`)
   можно удалить, если не используется.
7. **Dart-стиль:** strict-анализ, функции до ~150 строк, файлы до ~1100;
   именование как в upstream (`hlcNow` → `Hlc.now`, `nameId`, `wins`); комментарии
   к портированным модулям указывают источник (`ported from web/src/lib/…`).

## Карта контрактов (что читать перед задачей)

| Тема | Upstream-источник | Векторы/фикстуры |
| --- | --- | --- |
| Протокол обмена, device ids, paging, rejected, generation, scopes | `docs/sync.md` (Exchange, Device ids, Sharing scopes, Log generation) | — |
| REST: auth, токены, me, encryption keys, ошибки | `docs/api.md` (Authentication, Endpoints) | `docs/openapi.json` |
| Op-схема, дефолты строк, content-поля | `internal/sync/ops.go`, `web/src/generated/opSchema.ts` | — |
| HLC | `web/src/lib/hlc.ts` | `web/src/lib/hlc.vectors.json` |
| Ids (NameID, occurrence) | `web/src/lib/ids.ts`, `internal/ids` | эталоны в `test/ids_test.dart` |
| E2EE | `web/src/lib/crypto.ts`, `e2eeEnvelope.ts`, `e2ee.ts` | `web/src/lib/e2ee.vectors.json` (уже в `test/vectors/`) |
| Даты, zoned due | `web/src/lib/dates.ts`, `internal/zoned` | `zoned.vectors.json` |
| Inbox | `web/src/lib/inbox.ts`, `internal/inbox` | `inbox.vectors.json` |
| Today/списки дня | `web/src/lib/dayLists.ts`, `closedList.ts` | `closedList.vectors.json` |
| Recurrence | `web/src/lib/recurrence.ts`, `internal/recurrence`, `docs/recurrence.md` | `recurrence.vectors.json`, `occurrences.vectors.json`, `web/src/lib/testdata/check10.ts` |
| Напоминания | `docs/sync.md` §Reminders, `web/src/lib/defaultReminder.ts` | `defaultReminder.vectors.json` |
| Фильтры | `web/src/lib/filter/evaluate.ts`, `internal/filter` | `filter/evaluate.vectors.json` |
| Urgency | `web/src/lib/urgency.ts`, `internal/urgency` | `urgency.vectors.json` |
| Saved views | `web/src/lib/views.ts` | `views.vectors.json` |
| Дизайн-токены | `web/src/index.css`, `docs/design-system.md` | — |
| Клиентский цикл синхронизации | `web/src/lib/sync.ts`, `ops.ts`, `db.ts` | — |

## Что уже сделано (M0) — не переписывать без причины

- `lib/core/hlc.dart` — HLC + `wins()`; тесты поведения (`test/hlc_test.dart`).
  **Долг:** прогнать ещё и `hlc.vectors.json` (задача M0.1).
- `lib/core/ids.dart` — uuid v4, nameId/occurrenceId/pieceId/detachedId; эталоны
  посчитаны независимо (Python hashlib).
- `lib/core/op.dart` — модель op + LWW-сравнение.
- `lib/core/schema_generated.dart` — OP_DEFAULTS (22 сущности) + OP_CONTENT_FIELDS (40 полей).
- `lib/core/e2ee.dart` — полный порт crypto.ts + e2eeEnvelope.ts: конверты enc:v1,
  PBKDF2-SHA256, AES-KW (RFC 3394), HKDF, recovery key (base32+checksum), key record
  lifecycle, файловые конверты OTAT1, content-слой (seal/open).
- `test/e2ee_test.dart` — 40+ тестов против векторов Go-сервера; всё зелёное.
- `lib/main.dart` — пока шаблон Flutter (заменяется в M3).

## Грабли, на которые уже наступили (не повторять)

1. **AES-KW (RFC 3394):** блок = **конкатенация** `A || R[i]`, не XOR. Проверено
   вектором RFC 3394 §4.1 и серверными векторами.
2. **pointycastle `HkdfParameters`** — позиционные аргументы `(ikm, length, salt, info)`,
   не именованные. Пустой salt заменяется на null (нули длины hashLen) — передавать
   именно 32 нулевых байта, как Web Crypto.
3. **PBKDF2:** пароли нормализовать **NFC** (`unorm_dart`), иначе не-ASCII passphrase
   не совпадёт с веб-клиентом. 600k итераций в чистом Dart — секунды: только при
   unlock, не в UI-потоке (isolate).
4. **Границы итераций** `iterationLimitMin/Max` изменяемы для тестов (как
   `ITERATION_LIMITS` в crypto.ts); в проде — 600k…10M.
5. **Dart top-level const:** после закрывающей `}` карты нужна `;` (генератор схемы
   уже исправлен).
6. **Credential-маршруты** (`PUT /api/v1/encryption/keys`, токены, 2FA…): bearer `full`
   получает 403. Нужна сессионная cookie. Не-браузерный клиент: **без заголовка Origin**,
   `Content-Type: application/json` — тогда cookie-запись принимается.
7. **Device id:** один UUID на установку, хранить в meta, переиспользовать вечно;
   префикс `flutter:` допустим; зарезервированные (`server`, `agent:`, `caldav:`, …)
   сервер отклоняет. Pull пропускает ops своего device — два клиента с одним id
   не увидят правки друг друга.
8. **Generation mismatch** (restore сервера): reseed — переэмиттировать все поля
   локальных строк новыми op-id со **старыми** часами, cursor=0. Не bumpать ts.
9. **`rejected` в ответе обмена:** `invalid`/`forbidden` — дропнуть локальную правку и
   принять серверное значение из того же ответа; `unknown_field` — удерживать и
   пробовать снова (сервер может обновиться). Без feature `invalid_ops` один плохой
   op валит весь батч 400 — всегда отправлять `invalid_ops`.
10. **Относительные напоминания:** при смене `due` писать `fire_at` всех живых relative
    reminders **в том же батче с тем же ts/device**; при переносе огня clears
    `delivered_at`/`dismissed_at`. Date-only due считается как 09:00 локально.

## Definition of Done для любой задачи

- [ ] `dart analyze` — без error и warning
- [ ] `flutter test` — всё зелёное, включая новые тесты задачи
- [ ] Векторы (если есть) скопированы без правок и прогоняются
- [ ] Upstream-репозиторий не изменён (`git -C ~/Projects/OpenTodo status` чистый)
- [ ] Коммит с осмысленным сообщением; секреты не попали в код/тесты/доки
- [ ] Отметка задачи в PLAN.md (`[x]`) и краткий итог: что сделано, что осталось

## Параллельная работа агентов

- Задачи M2.* (доменные порты) — чистые функции над строками, **не зависят от M1**
  и делаются параллельно разными агентами. Каждая берёт свой файл векторов.
- M3.1 (дизайн-токены) независима от всего.
- M1.1 → M1.2/M1.3; M1.4 → M1.5 → M1.6; M1.7 после M1.4. Не брать задачу, чьи
  зависимости не закрыты (см. PLAN.md).
- Один агент — одна задача за раз; общие файлы (`pubspec.yaml`, `PLAN.md`) править
  точечно, не перезаписывать целиком.
