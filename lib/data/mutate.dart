// Local writes: one batch of changes becomes ops with one HLC timestamp and
// this installation's device id, applied optimistically to the store and
// queued in the outbox in one transaction; then the sync engine is asked to
// exchange.
//
// ported from web/src/lib/ops.ts (`mutateMany`, `withCompletedBy`,
// `checkEncryptedSize`, `reminderFollowUps`, `planTask`/`createTask`,
// `nextTaskPosition`) and web/src/lib/defaultReminder.ts
// (`defaultReminderChanges`). Encryption is not done here: like the web client
// the outbox holds plaintext and lib/data/e2ee_sync.dart seals content at
// upload.
//
// Not ported (no local support yet): rich-text note pairs (notes_doc is never
// written, AGENTS.md rule 4), time-sector clears, workspaces, activity log,
// quick-add reminder phrases.

import 'dart:async';
import 'dart:convert';

import '../core/e2ee.dart' show isContentField, maxPlaintextBytes;
import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/op.dart';
import '../core/schema_generated.dart';
import '../domain/change.dart';
import '../domain/default_reminder.dart';
import '../domain/reminders.dart';
import 'rows.dart';
import 'store.dart';

/// Distance between neighbouring manual positions (web ordering.ts GAP).
const int positionGap = 1000;

/// The entity id of the signed-in person's preferences row.
const String userPrefsId = 'me';

/// A write the client must not make: a note document or its appends (Yjs, not
/// merged here), or a plain-text description of an entity that has a document
/// (AGENTS.md rule 4: it would overwrite someone's rich text).
class ProtectedFieldError extends StateError {
  ProtectedFieldError(super.message);
}

/// A content value too long to fit the server's value limit once encrypted
/// (web PlaintextTooLongError). Nothing of the batch was written.
class PlaintextTooLongError extends StateError {
  final String entity;
  final String entityId;
  final String field;
  PlaintextTooLongError(this.entity, this.entityId, this.field)
      : super('This text is too long to encrypt ($entity.$field).');
}

/// The input of [Mutator.createTask] (web NewTaskInput, the fields this client
/// sets today).
class NewTask {
  final String title;
  final String description;
  final String? projectId;
  final String? parentId;
  final String? sectionId;

  /// 1 (highest) … 4 (none).
  final int priority;

  /// A due as JSON (`Due.toJson()`), or null.
  final Map<String, Object?>? due;
  final String? deadline;
  final List<String> labels;
  final int? estimateMinutes;
  final bool completed;

  const NewTask({
    required this.title,
    this.description = '',
    this.projectId,
    this.parentId,
    this.sectionId,
    this.priority = 4,
    this.due,
    this.deadline,
    this.labels = const [],
    this.estimateMinutes,
    this.completed = false,
  });
}

class Mutator {
  final SyncStore store;

  /// The clock shared with the sync engine (one per installation).
  final Hlc hlc;

  /// This installation's device id (the one the engine sends).
  final String device;

  /// Called after every committed batch; the app passes `engine.requestSync`.
  final void Function()? onMutated;

  /// The signed-in account id (`completed_by`, default reminder ids).
  final String? Function() userId;

  /// Whether the account encrypts: content over [maxPlaintextBytes] is refused.
  final bool Function() encrypted;

  /// The zone floating dues are read in (null: the viewer's zone).
  final String? Function() zone;

  /// Wall clock in Unix ms (created_at, positions, reminder created_at).
  final int Function() clock;

  final String Function() newId;

  Future<void> _tail = Future.value();
  int? _issuedPosition;

  Mutator({
    required this.store,
    required this.hlc,
    required this.device,
    this.onMutated,
    String? Function()? userId,
    bool Function()? encrypted,
    String? Function()? zone,
    int Function()? clock,
    String Function()? newId,
  })  : userId = userId ?? (() => null),
        encrypted = encrypted ?? (() => false),
        zone = zone ?? (() => null),
        clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        newId = newId ?? uuid;

  /// Writes [changes] as ONE batch: the default reminder of a task that gets a
  /// due date (skipped with [restore]: Undo, Trash) and the `fire_at` of its
  /// relative and deadline reminders join it, every op gets the same `ts` and
  /// `device`, the store and outbox are updated in one transaction, and the
  /// engine is asked to sync. Returns the ops written (empty when nothing
  /// changed). Throws [ProtectedFieldError] or [PlaintextTooLongError] before
  /// anything is written.
  Future<List<Op>> mutate(List<Change> changes, {bool restore = false}) => _serial(() => _mutate(changes, restore));

  /// Creates a task with the schema defaults and a fresh uuid, appended at the
  /// end of its list; returns its id.
  Future<String> createTask(NewTask input) => _serial(() async {
        final id = newId();
        final now = clock();
        final patch = <String, Object?>{
          'title': input.title.trim(),
          'description': input.description,
          'project_id': input.projectId,
          'parent_id': input.parentId,
          'priority': input.priority,
          'due': input.due,
          'labels': input.labels,
          'position': await _nextTaskPosition(now),
          'created_at': now,
          'completed_at': input.completed ? now : null,
          'deleted_at': null,
          'estimate_minutes': input.estimateMinutes,
          // Only tasks created in a section or with a deadline carry the field.
          if (input.sectionId != null) 'section_id': input.sectionId,
          if (input.deadline != null) 'deadline': input.deadline,
        };
        await _mutate([Change('task', id, patch)], false);
        return id;
      });

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<Op>> _mutate(List<Change> input, bool restore) async {
    var changes = [...input];
    _checkEncryptedSize(changes);
    await _checkProtected(changes);
    final reminders = await _remindersByTask(changes);
    Iterable<Map<String, Object?>> remindersOf(String taskId) => reminders[taskId] ?? const [];
    if (!restore) changes = [...changes, ...await _defaultReminders(changes, remindersOf)];
    changes = withReminderFollowUps(changes, remindersOf, zone: zone());
    changes = withCompletedBy(changes, userId() ?? '');
    if (!changes.any((c) => c.patch.isNotEmpty)) return const [];

    final written = await store.transaction((tx) async {
      hlc.seed(await tx.hlcLast);
      final ops = changesToOps(changes, ts: hlc.now(), device: device, newId: newId);
      await tx.applyOps(ops);
      await tx.appendOutbox(ops);
      await tx.setHlcLast(hlc.last);
      return ops;
    });
    onMutated?.call();
    return written;
  }

  /// Rule 4: never notes_doc / appends.*, and description only while the
  /// entity has no document (neither stored nor in this batch).
  Future<void> _checkProtected(List<Change> changes) async {
    for (final c in changes) {
      for (final f in c.patch.keys) {
        if (f == 'notes_doc' || f == 'appends' || f.startsWith('appends.')) {
          throw ProtectedFieldError('${c.entity}.$f is a note document; this client does not write it');
        }
      }
      if (!c.patch.containsKey('description') || !(opDefaults[c.entity]?.containsKey('notes_doc') ?? false)) continue;
      final doc = (await store.getField(c.entity, c.entityId, 'notes_doc'))?.value;
      if (doc is String && doc.isNotEmpty) {
        throw ProtectedFieldError('${c.entity} ${c.entityId} has a note document; its description is not plain text');
      }
    }
  }

  void _checkEncryptedSize(List<Change> changes) {
    if (!encrypted()) return;
    for (final c in changes) {
      c.patch.forEach((field, value) {
        if (value is String &&
            value.length > maxPlaintextBytes ~/ 4 &&
            isContentField(c.entity, field) &&
            utf8.encode(value).length > maxPlaintextBytes) {
          throw PlaintextTooLongError(c.entity, c.entityId, field);
        }
      });
    }
  }

  /// Reminder rows (with deleted ones) of every task whose due or deadline the
  /// batch writes, by task id.
  Future<Map<String, List<Map<String, Object?>>>> _remindersByTask(List<Change> changes) async {
    final tasks = {
      for (final c in changes)
        if (c.entity == 'task' && (c.patch.containsKey('due') || c.patch.containsKey('deadline'))) c.entityId,
    };
    if (tasks.isEmpty) return const {};
    final out = <String, List<Map<String, Object?>>>{};
    for (final r in await loadRows(store, 'reminder', includeDeleted: true)) {
      final t = r['task_id'];
      if (t is String && tasks.contains(t)) out.putIfAbsent(t, () => []).add(r);
    }
    return out;
  }

  Future<List<Change>> _defaultReminders(List<Change> changes, RemindersOf remindersOf) async {
    final uid = userId();
    if (uid == null || uid.isEmpty || !changes.any((c) => c.entity == 'task' && c.patch['due'] != null)) {
      return const [];
    }
    final prefs = readDefaultReminders(await loadRow(store, 'user_prefs', userPrefsId));
    if (prefs.timed == null && prefs.dated == null) return const [];
    final rows = <String, Map<String, Object?>?>{};
    for (final c in changes) {
      if (c.entity == 'task' && !rows.containsKey(c.entityId)) rows[c.entityId] = await loadRow(store, 'task', c.entityId);
    }
    return defaultReminderChanges(
      changes,
      userId: uid,
      prefs: prefs,
      taskRow: (id) => rows[id],
      remindersOf: remindersOf,
      now: clock(),
      zone: zone(),
    );
  }

  /// After every task, unless some task was moved past the creation time; two
  /// tasks created at once get increasing positions (web nextTaskPosition).
  Future<num> _nextTaskPosition(int now) async {
    num? top;
    for (final row in (await store.readEntity('task')).values) {
      final p = row['position']?.value;
      if (p is num && p.isFinite && (top == null || p > top)) top = p;
    }
    num position = top != null && top >= now ? top + positionGap : now;
    final issued = _issuedPosition;
    if (issued != null && (top == null || issued > top) && position <= issued && issued - position < positionGap) {
      position = issued + 1;
    }
    _issuedPosition = position.toInt();
    return position;
  }
}

/// A task completed in the batch records who completed it; reopening clears
/// it; a new task created open does not carry it (web ops.ts withCompletedBy).
List<Change> withCompletedBy(List<Change> changes, String actor) {
  if (!changes.any((c) => c.entity == 'task' && c.patch.containsKey('completed_at') && !c.patch.containsKey('completed_by'))) {
    return changes;
  }
  return [
    for (final c in changes)
      if (c.entity != 'task' || !c.patch.containsKey('completed_at') || c.patch.containsKey('completed_by'))
        c
      else if (c.patch['completed_at'] == null && c.patch.containsKey('created_at'))
        c
      else
        Change(c.entity, c.entityId, {
          ...c.patch,
          'completed_by': c.patch['completed_at'] != null ? (actor.isEmpty ? null : actor) : null,
        }),
  ];
}
