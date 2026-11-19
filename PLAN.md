# План работ (задачи для агентов-исполнителей)

Каждая задача самодостаточна: цель, что читать, что создать, критерии приёмки.
Перед работой прочитать **[AGENTS.md](AGENTS.md)** (правила, карта контрактов, грабли).
Отмечать выполнение `[x]` прямо здесь. Зависимости указаны явно; задачи без
незакрытых зависимостей можно брать параллельно разными агентами.

Легенда: **Читать** — контракты в upstream (`~/Projects/OpenTodo`);
**Создать** — файлы в этом проекте; **Приёмка** — проверяемые условия.

---

## M0. Фундамент — ГОТОВО ✅

- [x] M0.0 Проект, зависимости, генератор схемы, HLC, ids, op-модель, E2EE
      (54 теста против векторов Go-сервера проходят)

Долги M0 (мелкие, брать первыми):

- [x] **M0.1 HLC: прогон общих векторов**
  Читать: `web/src/lib/hlc.vectors.json`, `web/src/lib/hlc.ts`.
  Создать: `test/vectors/hlc.vectors.json` (копия), `test/hlc_vectors_test.dart`.
  Приёмка: все кейсы векторов проходят; существующие тесты не сломаны.

- [x] **M0.2 Генератор схемы: убрать lint-замечания**
  Создать: правка `tool/sync_schema.mjs` — в doc-комментариях генерируемого файла
  обернуть `<id>` в backticks; регенерировать `lib/core/schema_generated.dart`.
  Приёмка: `dart analyze` по проекту — 0 замечаний; тесты зелёные.

---

## M1. Слой данных и синхронизация

- [x] **M1.1 SyncStore: интерфейс + in-memory реализация**
  Читать: `docs/sync.md` (Exchange, Log generation), `web/src/lib/db.ts` (структура хранения).
  Создать: `lib/data/store.dart` — интерфейс `SyncStore`:
  поля `(entity, entityId, field) → {valueJson, ts, device}`, чтение строки/всех строк
  сущности, запись поля по winner rule, outbox (append, read до 500, delete по id),
  meta (cursor, generation, deviceId, hlc, hlcOffset, произвольные ключи),
  транзакционность применения батча; `MemoryStore` для тестов.
  Приёмка: unit-тесты winner rule (tie по device), идемпотентность повторного op,
  семьи `fields.<id>`/`appends.<id>` хранятся как отдельные поля.

- [x] **M1.2 SyncStore: SQLite-реализация**
  Читать: M1.1 интерфейс; `sqflite` docs.
  Создать: `lib/data/store_sqflite.dart` (таблицы `fields`, `outbox`, `meta`,
  индексы по entity/entityId), миграции схемы БД через `onCreate/onUpgrade`;
  `test/store_sqflite_test.dart` на `sqflite_common_ffi`.
  Приёмка: те же тесты, что M1.1, проходят на SQLite; перезакрытие БД сохраняет
  состояние; транзакция батча атомарна.

- [x] **M1.3 Материализация строк**
  Читать: `lib/core/schema_generated.dart` (opDefaults), `web/src/lib/ops.ts`
  (как поля собираются в строку, семьи `fields`/`appends`/`reactions`).
  Создать: `lib/data/rows.dart` — сборка строки сущности из полей с дефолтами,
  типизированные модели `Task`, `Project`, `Label`, `Section`, `Reminder`, `UserPrefs`
  (остальные сущности — generic Map до востребованности); tombstone-фильтрация.
  Приёмка: тесты на дефолты каждой MVP-сущности; отсутствующее поле → дефолт;
  `deleted_at != null` исключает строку из списков.

- [ ] **M1.4 ApiClient (REST)**
  Читать: `docs/api.md` §Authentication (поток `ot login`: login → cookie →
  POST tokens → secret → logout; MFA challenge → POST auth/mfa), §Health and
  authentication, §End-to-end encryption (GET/PUT encryption/keys), грабли №6 в AGENTS.md.
  Создать: `lib/data/api.dart` — `ApiClient(baseUrl, {http.Client})`:
  `health()` (GET /api/v1/health, fallback /healthz), `login(email, password)`
  (cookie-jar, ответ `{mfaRequired, challenge}`), `mfa(challenge, code)`,
  `createToken(name)` (без Origin, JSON), `logout()`, `me()`,
  `getKeyRecord()` / `putKeyRecord(record)` (cookie-сессия!),
  bearer-режим для остальных запросов, таймаут 30 с, backoff с jitter (1→30 с),
  разбор error-envelope `{error:{code,message}}`.
  Приёмка: тесты с фейковым `http.Client`: полный login-поток, MFA-ветка,
  401 → ошибка авторизации, 429 → backoff, cookie не утекает в bearer-запросы.

- [ ] **M1.5 SyncEngine: обмен**
  Читать: `docs/sync.md` целиком (Exchange, Device ids, Paging, Sharing scopes,
  Log generation, Clocks), `web/src/lib/sync.ts` (цикл), грабли №7–9 в AGENTS.md.
  Создать: `lib/data/sync_engine.dart`:
  запрос `{device, cursor, ops[≤500], features:["clock_skew","invalid_ops"], tzOffset}`;
  успех → удалить отправленные из outbox, применить возвращённые ops (winner rule,
  `hlc.receive`), обработать `rejected` (invalid/forbidden → серверное значение;
  unknown_field → удержать), сохранить cursor; `hasMore` или непустой outbox → повтор;
  `generation` mismatch → reseed (все поля всеми строками, новые op-id, старые часы,
  cursor=0); `serverTime` → `hlc.observeServerTime`; `clock_skew`-отказ →
  `hlc.clockRefused` и повтор; дубликаты не применять повторно;
  триггеры: после локальной правки (debounce 250 мс), периодически 30 с, вручную.
  Приёмка: тесты с фейковым сервером (in-memory op-log с Apply/Pull по протоколу):
  (а) два «устройства» правят офлайн одно поле → конвергенция по (ts, device);
  (б) paging >1000 ops; (в) reseed после смены generation; (г) rejected invalid →
  локальная правка заменена серверной; (д) ops своего device не приходят в pull;
  (е) идемпотентность повторной отправки.

- [ ] **M1.6 Локальные записи + E2EE в обмене**
  Читать: `web/src/lib/ops.ts` (`mutate`), `e2eeSync.ts` (seal/open на границе),
  `lib/core/e2ee.dart` (готовый content-слой).
  Создать: `lib/data/mutate.dart` — `mutate(changes)`: батч ops с `hlc.now()` и
  deviceId установки, оптимистичное применение в store, seal контентных полей
  личного scope при включённом E2EE, запись в outbox, триггер движка;
  open входящих конвертов при применении (ошибка расшифровки → значение-заглушка,
  не падать). Создание задачи: `created_at`, дефолты, id=uuid.
  Приёмка: тесты: правка offline → в outbox → после обмена сервер видит конверт
  (для encrypted) или plaintext; входящий конверт расшифровывается; tampered
  конверт не роняет применение батча.

- [ ] **M1.7 Состояние аккаунта и безопасное хранение**
  Читать: `docs/api.md` §me (`encryption: {enabled, keyVersion}`), `docs/e2ee.md`.
  Создать: `lib/data/account.dart` — `AccountState` (serverUrl, userId, email,
  encrypted, keyVersion, deviceId); токен и DEK — `flutter_secure_storage`;
  сессионная cookie — в памяти/secure storage; sign-out: остановить движок,
  очистить БД и secure storage (epoch, как `stopSync` в web).
  Приёмка: тесты с фейковым secure storage: сохранение/восстановление сессии,
  sign-out очищает всё, смена сервера = новый deviceId не требуется, но данные сбрасываются.

- [ ] **M1.8 Контрактный тест против живого сервера** ⚠️ нужен тестовый аккаунт
  Читать: AGENTS.md (сервер), `docs/api.md`.
  Создать: `test/integration/live_server_test.dart` (пропускается без env
  `OT_TEST_URL`/`OT_TEST_TOKEN`): health → sync пустого аккаунта → создать задачу
  через op-log → прочитать её через REST → изменить с второго «device» → конвергенция →
  удалить (tombstone). Для E2EE-аккаунта: seal/unseal через реальный обмен.
  Приёмка: тест проходит против Railway-сервера с тестовым аккаунтом
  (создаётся владельцем через приглашение; токен — в env, не в коде).
  Зависимости: M1.4–M1.7. **Токен запросить у пользователя, не создавать самому.**

---

## M2. Доменная логика (параллельно, не зависит от M1)

Все задачи — чистые функции над материализованными строками (M1.3 даёт модели,
но порты можно писать против Map-строк и уточнить типы после M1.3).

- [ ] **M2.1 Даты и zoned due**
  Читать: `web/src/lib/dates.ts`, `docs/sync.md` §Zoned due values, `internal/zoned`.
  Создать: `lib/domain/dates.dart` (парсинг/форматирование due, «сегодня» с учётом
  day_start, разрешение zoned-значений в момент: gap → первый валидный, overlap →
  первый), `test/vectors/zoned.vectors.json`, тесты.
  Приёмка: все векторы zoned проходят.

- [ ] **M2.2 Inbox**
  Читать: `web/src/lib/inbox.ts`, `internal/inbox`.
  Создать: `lib/domain/inbox.dart`, `test/vectors/inbox.vectors.json`, тесты.
  Приёмка: все векторы inbox проходят.

- [ ] **M2.3 Today и Upcoming**
  Читать: `web/src/lib/dayLists.ts`, `closedList.ts`, `docs/day-parts.md`,
  `web/src/lib/dayParts.ts`.
  Создать: `lib/domain/today.dart` (просрочено/сегодня/вечер, day parts,
  сортировки), `lib/domain/upcoming.dart` (группировка по дням),
  `test/vectors/closedList.vectors.json`, тесты.
  Приёмка: векторы closedList проходят; тесты Today на граничные случаи
  (просроченные, evening, zoned due в чужой зоне).

- [ ] **M2.4 Recurrence: грамматика и следующее повторение**
  Читать: `docs/recurrence.md`, `web/src/lib/recurrence.ts`, `internal/recurrence`,
  `web/src/lib/testdata/check10.ts` (замороженная грамматика 1.0).
  Создать: `lib/domain/recurrence.dart` (парсер, canonical form, `Compatible`,
  next occurrence после даты, until/count), `test/vectors/recurrence.vectors.json`,
  `test/vectors/occurrences.vectors.json`, тесты.
  Приёмка: оба набора векторов проходят; правила сохраняются в compatible-форме.

- [ ] **M2.5 Завершение повторяющихся задач**
  Читать: `docs/sync.md` §Recurring tasks, `docs/recurrence.md` (one occurrence alone),
  `lib/core/ids.dart` (occurrenceId готов).
  Создать: `lib/domain/complete.dart` — батч завершения: occurrence record
  (id=occurrenceId, поля серии, completed_at, recurrence=null, series_id,
  occurrence_date) + due серии на следующее повторение; skip; «только это
  повторение»; ремонт серии, вставшей на дату-исключение.
  Приёмка: тесты: два офлайн-завершения одного повторения → один record
  (одинаковый id и due); серия не стоит на датах-исключениях.
  Зависимости: M2.4.

- [ ] **M2.6 Напоминания: расписание и fire_at**
  Читать: `docs/sync.md` §Reminders, `web/src/lib/defaultReminder.ts`,
  `docs/push-notifications.md` §In the Android app.
  Создать: `lib/domain/reminders.dart` — relative (due+offset; date-only → 09:00
  локально; zoned → свой момент), absolute, deadline (09:00 дня deadline+offset);
  пересчёт fire_at всех живых relative при смене due (тот же батч/ts/device,
  clears delivered/dismissed); snooze/dismiss ops; правило показа
  (fire_at ≤ now, не dismissed для текущего огня, задача жива).
  Приёмка: векторы defaultReminder проходят; тесты переноса due и гонок
  delivery/snooze.
  Зависимости: M2.1.

- [ ] **M2.7 Фильтры saved views**
  Читать: `web/src/lib/filter/evaluate.ts`, `internal/filter`, `docs/filters.md`.
  Создать: `lib/domain/filter.dart` (парсер query + evaluator),
  `test/vectors/filter/evaluate.vectors.json`, тесты.
  Приёмка: все векторы evaluate проходят.

- [ ] **M2.8 Urgency-сортировка**
  Читать: `web/src/lib/urgency.ts`, `internal/urgency`.
  Создать: `lib/domain/urgency.dart`, `test/vectors/urgency.vectors.json`, тесты.
  Приёмка: все векторы urgency проходят.

---

## M3. UI-ядро

- [ ] **M3.1 Дизайн-токены → Flutter-тема**
  Читать: `web/src/index.css` (токены: цвета, радиусы, elevation, типографика),
  `docs/design-system.md`.
  Создать: `lib/ui/theme.dart` (светлая/тёмная темы из токенов, ThemeExtension
  для семантических цветов), `lib/ui/tokens.dart`; удалить неиспользуемый
  `material_ui` из pubspec; заменить шаблонный `main.dart` каркасом приложения.
  Приёмка: golden-тест палитры/компонентов; `flutter analyze` чистый.

- [ ] **M3.2 Каркас и навигация**
  Читать: M3.1; `web/src/app/` (структура экранов веба — ориентир).
  Создать: `lib/ui/app.dart` — bottom navigation (Today / Inbox / Projects / Search),
  роутинг, sync-статус pill (synced/syncing/offline/error), pull-to-sync,
  офлайн-индикатор; подключение SyncEngine к UI через stream состояний.
  Приёмка: навигация работает, статус синхронизации отображает состояния движка
  (тесты с фейковым движком).
  Зависимости: M3.1, M1.5.

- [ ] **M3.3 Setup и Sign-in**
  Читать: `docs/api.md` §Authentication; `mobile/README.md` §How it fits together
  (правила адреса: https, http только для локальных после предупреждения).
  Создать: `lib/ui/screens/setup.dart` (адрес сервера + health-проверка с названными
  ошибками), `lib/ui/screens/sign_in.dart` (email/password, MFA-код, ошибки
  rate-limit/неверный пароль), восстановление сессии при запуске.
  Приёмка: widget-тесты: неверный адрес → понятная ошибка; MFA-ветка; успешный
  вход ведёт на Today.
  Зависимости: M1.4, M1.7, M3.1.

- [ ] **M3.4 Списки: Today / Inbox / Project**
  Читать: M2.2, M2.3; `web/src/app/` (внешний вид строк — ориентир).
  Создать: `lib/ui/screens/today.dart`, `inbox.dart`, `project.dart`,
  `lib/ui/widgets/task_row.dart` (чекбокс, приоритет, due, метки, свайпы
  done/delete), секции и группировки, пустые состояния.
  Приёмка: widget-тесты на данных из store: рендер списков, тап по чекбоксу →
  mutate completion, свайп → tombstone; списки обновляются после обмена.
  Зависимости: M1.3, M1.6, M2.2, M2.3, M3.2.

- [ ] **M3.5 Редактор задачи**
  Читать: `docs/sync.md` §Schema (поля task), M2.4–M2.6.
  Создать: `lib/ui/screens/task_editor.dart` — title, description (plain text,
  только если notes_doc пуст — правило №4 AGENTS.md), due (date/time/zoned),
  priority 1–4, project, labels, reminder, repeat; сохранение батчем через mutate;
  создание задачи из списка/quick-add кнопки.
  Приёмка: widget-тесты: каждое поле порождает правильный op; правка офлайн
  уходит в outbox; заметка с документом не перезаписывается.
  Зависимости: M3.4, M2.1, M2.4, M2.6.

- [ ] **M3.6 Quick add**
  Читать: `web/src/lib/nlp/` (парсер), `docs/quick-add.md`.
  Создать: `lib/ui/widgets/quick_add.dart` + упрощённый парсер
  (`lib/domain/quickadd.dart`: title, !приоритет, #метка, @проект, даты «завтра»,
  «в пятницу», «15:00»); полный порт nlp — отдельной задачей позже.
  Приёмка: тесты парсера на типовых строках; строка создаёт задачу с разобранными
  полями одним батчем.
  Зависимости: M3.5.

---

## M4. E2EE как продукт

- [ ] **M4.1 Включение шифрования**
  Читать: `docs/e2ee.md`, `docs/api.md` §End-to-end encryption, грабли №6.
  Создать: `lib/ui/screens/encryption_setup.dart` — passphrase ≥12 символов,
  генерация key record (`createKeyRecord` готов), показ recovery key один раз
  (копирование, подтверждение «я сохранил»), PUT через сессионную cookie,
  после успеха — пометить аккаунт encrypted и перешифровать существующие
  локальные контентные поля (батч re-encrypt, как web).
  Приёмка: тесты с фейковым API: полный поток; recovery key показывается ровно
  один раз; PUT идёт с cookie, не с bearer.
  Зависимости: M1.4, M1.6, M1.7, M3.2.

- [ ] **M4.2 Unlock и locked-состояние**
  Читать: `docs/e2ee.md`, `lib/core/e2ee.dart` (unlockWithPassphrase/RecoveryKey).
  Создать: `lib/ui/screens/unlock.dart` (passphrase / recovery key, PBKDF2 в
  isolate, ошибка WrongSecret → понятное сообщение), locked-экран вместо данных,
  хранение DEK в secure storage на время сессии.
  Приёмка: widget-тесты: верная passphrase открывает данные; неверная — ошибка;
  recovery key работает; после перезапуска — снова unlock.
  Зависимости: M4.1.

- [ ] **M4.3 Смена passphrase и сброс**
  Читать: `lib/core/e2ee.dart` (rewrapWithPassphrase/resetWithRecoveryKey готовы),
  `docs/e2ee.md`.
  Создать: экраны настроек шифрования: смена passphrase (re-wrap, контент не
  перешифровывается), сброс через recovery key (новый recovery key показать),
  выключение шифрования — только через веб (credential+fresh, сложно; отложить).
  Приёмка: тесты потоков против фейкового API; старый recovery key после сброса
  не работает.
  Зависимости: M4.2.

- [ ] **M4.4 Кросс-клиентная проверка E2EE**
  Создать: расширение M1.8: аккаунт, зашифрованный ВЕБ-клиентом, открывается
  Flutter-клиентом (unlock passphrase, чтение конвертов); правка из Flutter
  читается вебом.
  Приёмка: ручной сценарий задокументирован в `docs/e2ee-verification.md`
  и пройден; автотест на seal/open против векторов уже есть (M0).
  Зависимости: M1.8, M4.2.

---

## M5. Нативные возможности

- [ ] **M5.1 Напоминания-уведомления**
  Читать: `mobile/README.md` §ReminderSchedule/Reminders (поведение-эталон),
  `docs/push-notifications.md`; M2.6.
  Создать: `lib/native/reminders.dart` — flutter_local_notifications, расписание
  на 7 дней вперёд из store, exact alarms (Android 12+ permission flow с объяснением),
  кнопки Done / Snooze 10 min / Dismiss (действия пишут ops через скрытый sync),
  перепланирование после перезагрузки и после каждого обмена.
  Приёмка: unit-тесты расписания; instrumented-тест уведомления на эмуляторе;
  Done из уведомления завершает задачу офлайн.
  Зависимости: M2.6, M1.6.

- [ ] **M5.2 Share intent**
  Читать: `mobile/README.md` §ShareTest (лимиты: 10 файлов, 20 МБ каждый, 25 МБ всего).
  Создать: `lib/native/share.dart` — приём текста/ссылок/файлов → экран capture →
  задача (title/описание/вложение позже).
  Приёмка: текст и ссылка создают задачу; лимиты соблюдаются.
  Зависимости: M3.5.

- [ ] **M5.3 Виджет Today**
  Читать: `mobile/README.md` §WidgetModel (данные виджета: до 50 задач, counts
  на локскрине).
  Создать: `lib/native/widget.dart` (home_widget) + Android-виджет; публикация
  данных после обмена.
  Приёмка: виджет показывает задачи Today; на локскрине — только counts.
  Зависимости: M2.3, M1.5.

- [ ] **M5.4 Биометрия**
  Читать: `mobile/README.md` §BiometricKeyStore (ключ под биометрией, инвалидация
  при смене отпечатков).
  Создать: `lib/native/biometric.dart` — local_auth + secure storage
  (biometric-gated), разблокировка DEK без passphrase.
  Приёмка: включение/выключение в настройках; смена биометрии инвалидирует ключ.
  Зависимости: M4.2.

- [ ] **M5.5 Фоновое обновление**
  Создать: WorkManager-задача (~раз в час): sync + перепланирование напоминаний +
  публикация виджета.
  Приёмка: расписание обновляется без открытия приложения (проверка на эмуляторе).
  Зависимости: M5.1, M5.3.

---

## M6. Расширение (после первого используемого клиента)

- [ ] **M6.1 SSE live-канал** — `GET /api/v1/sync/events?device=…`, пробуждение
      обмена по cursor, backoff 1→30 с, polling 30 с → 5 мин при подключённом канале
      (`docs/sync.md` §Live updates).
- [ ] **M6.2 Заметки: решение и реализация** — исследовать `yrs` (Rust Yjs) через
      FFI vs plain-text навсегда; если FFI: порт merge-правил `docs/sync.md`
      §Mergeable documents + `web/src/lib/richtext.ts`. До решения — правило №4.
- [ ] **M6.3 Привычки** — `habits.vectors.json`, `internal/habits`.
- [ ] **M6.4 Поиск** — локальный FTS по title/description (SQLite FTS5).
- [ ] **M6.5 Вложения и комментарии** — `docs/api.md` §Attachments, §Comments.
- [ ] **M6.6 iOS** — сборка, подпись, TestFlight (инфраструктура upstream
      `mobile/ios` — ориентир по правилам).
- [ ] **M6.7 CI** — GitHub Actions: analyze + test + build APK; контрактные тесты
      по расписанию против тестового аккаунта.
- [ ] **M6.8 Дистрибуция** — GitHub-репозиторий, APK-релизы (Obtainium), LICENSE
      AGPL-3.0, README для пользователей; позже F-Droid/Play.

---

## Граф зависимостей (кратко)

```
M0.1, M0.2 ─────────────────────────────┐
M1.1 → M1.2                             │
M1.1 → M1.3                             │
M1.4 → M1.5 → M1.6 → M1.8               │  (M1 — последовательная цепочка,
M1.4 → M1.7                             │   кроме M1.1/M1.4 параллельны)
M2.1…M2.8 — параллельно, не зависят от M1 (кроме M2.5←M2.4, M2.6←M2.1)
M3.1 — независимо
M3.2 ← M3.1, M1.5
M3.3 ← M1.4, M1.7, M3.1
M3.4 ← M1.3, M1.6, M2.2, M2.3, M3.2
M3.5 ← M3.4, M2.1, M2.4, M2.6
M3.6 ← M3.5
M4.1 ← M1.4, M1.6, M1.7, M3.2 → M4.2 → M4.3; M4.4 ← M1.8, M4.2
M5.1 ← M2.6, M1.6; M5.2 ← M3.5; M5.3 ← M2.3, M1.5; M5.4 ← M4.2; M5.5 ← M5.1, M5.3
```

**Первый используемый клиент** = конец M4 (Today/Inbox/проекты, офлайн, E2EE).
**Рекомендуемый порядок взятия:** M0.1/M0.2 → параллельно {M1.1+M1.4, M2.1, M2.2,
M2.4, M2.7, M2.8, M3.1} → далее по графу.
