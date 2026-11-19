# OpenTodo Flutter

Нативный клиент (Flutter) для [OpenTodo](https://github.com/OpenTodoApp/OpenTodo) —
open-source self-hosted планировщика задач. Заменяет официальное Android-приложение
(тонкую WebView-оболочку) настоящим нативным интерфейсом с той же офлайн-синхронизацией
и сквозным шифрованием (E2EE).

## Зачем

Официальное приложение грузит веб-интерфейс в WebView: производительность UI как у веба.
Этот клиент рисует интерфейс нативно (Flutter, 120 Hz), хранит данные в локальной SQLite
и синхронизируется по документированному op-log протоколу сервера — как веб-приложение,
но без браузера. Сервер при этом **не модифицируется**: клиент говорит на стабильном
протоколе v1 и проверяет совместимость общими тестовыми векторами самого проекта OpenTodo.

## Статус

| Веха | Содержание | Статус |
| --- | --- | --- |
| M0 | Фундамент: HLC, id, схема, E2EE-криптография | ✅ готово, 54 теста против векторов сервера |
| M1 | Хранилище, API-клиент, движок синхронизации | план |
| M2 | Доменная логика (Today/Inbox, recurrence, reminders, фильтры) | план |
| M3 | UI-ядро (дизайн-токены OpenTodo, экраны, редактор) | план |
| M4 | E2EE как продукт (включение, recovery key, unlock) | план |
| M5 | Нативные возможности (уведомления, share, виджеты, биометрия) | план |
| M6 | Расширение (SSE, заметки, привычки, iOS, CI, дистрибуция) | план |

Задачи, критерии приёмки и зависимости: **[PLAN.md](PLAN.md)**.
Инструкции для AI-агентов и карта контрактов: **[AGENTS.md](AGENTS.md)**.

## Архитектура

```
┌─────────────────────────── Flutter-приложение ───────────────────────────┐
│  UI (Flutter, дизайн-токены OpenTodo)                                    │
│    Today / Inbox / Projects / Task editor / Settings                     │
│  Доменная логика (порты web/src/lib, закреплены векторами)               │
│    inbox, today, recurrence, reminders, filters, urgency                 │
│  Слой данных                                                             │
│    SyncStore (SQLite: fields + outbox + meta)                            │
│    SyncEngine (POST /api/v1/sync: обмен, paging, reseed)                 │
│    ApiClient (REST: auth, health, key record)                            │
│  Ядро (готово)                                                           │
│    HLC-часы · NameID/UUID · op-модель + LWW · схема (генерируется)        │
│    E2EE: AES-256-GCM конверты, PBKDF2+AES-KW, recovery key, OTAT1        │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │ https, op-log протокол v1
                    ┌──────────────▼──────────────┐
                    │  Сервер OpenTodo (Railway)  │
                    │  ghcr.io/opentodoapp/       │
                    │  opentodo:stable (v1.5.0)   │
                    └─────────────────────────────┘
```

- **Данные** — полевой op-log с last-writer-wins: каждое поле сущности — отдельный
  регистр с часами `(ts, device)`. Локальные правки применяются оптимистично и уходят
  в outbox; обмен с сервером идемпотентен и переживает офлайн.
- **Шифрование** — всё на клиенте: контентные поля личного scope шифруются
  AES-256-GCM с привязкой к `(entity, entityId, field)`; ключ аккаунта обёрнут
  парольной фразой (PBKDF2 600k + AES-KW) и recovery key (HKDF + AES-KW).
  Сервер видит только конверты `enc:v1:…`.
- **Совместимость** доказывается векторами: `test/vectors/` — копии файлов
  `web/src/lib/*.vectors.json` из upstream, которые генерирует и проверяет Go-сервер.

## Быстрый старт

```sh
flutter pub get
flutter test          # все тесты, включая known-answer векторы сервера
dart analyze          # статический анализ

# регенерация схемы полей из upstream-репозитория (после обновления сервера):
node tool/sync_schema.mjs ~/Projects/OpenTodo

flutter run           # запуск на подключённом устройстве/эмуляторе
```

## Связанные репозитории и сервер

- Upstream (источник контрактов, **read-only**: `~/Projects/OpenTodo`
  (https://github.com/OpenTodoApp/OpenTodo) — docs/sync.md, docs/api.md,
  web/src/lib/*.ts, *.vectors.json, internal/sync/ops.go.
- Рабочий сервер: Railway, проект `opentodo`, образ `opentodo:stable`.
  Адрес и переменные — в Railway dashboard (`railway status`, `railway variable list`
  из директории upstream-репозитория). Секреты в этот репозиторий не коммитятся.

## Лицензия

Upstream OpenTodo — AGPL-3.0. Этот клиент — производная работа от протокола и схемы;
при публичном распространении должен распространяться под AGPL-3.0.
Для личного использования обязательств нет.
