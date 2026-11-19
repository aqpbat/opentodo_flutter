// Row materialization: an entity row built from its stored registers on top of
// the schema defaults, ported from web/src/lib/ops.ts (`applyOps` row building,
// `familyOf`, `fieldValueId`, `appendId`, `reactionAccount`, `readField`).
//
// A row is a plain `Map<String, Object?>` with `id` plus one key per op field;
// a field family (`fields.<id>`, `appends.<id>`, `reactions.<account>`) lives in
// one map under its prefix. Fields this build does not know (a newer server)
// are kept under their op name. Typed models below are thin views over a row.

import '../core/schema_generated.dart';
import 'store.dart';

/// The op field prefix of a task's custom field values (custom-fields D2).
const String fieldValuePrefix = 'fields.';

/// The op field prefix of a comment's per-account reactions.
const String reactionPrefix = 'reactions.';

/// The op field prefix of a pending append on a task's or note's note.
const String appendPrefix = 'appends.';

final RegExp _familyId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

String? _suffix(String field, String prefix) {
  if (!field.startsWith(prefix)) return null;
  final id = field.substring(prefix.length);
  return _familyId.hasMatch(id) ? id : null;
}

/// The definition id of a `fields.<id>` op field, or null for any other field.
String? fieldValueId(String field) => _suffix(field, fieldValuePrefix);

/// The account id of a `reactions.<account>` op field, or null.
String? reactionAccount(String field) => _suffix(field, reactionPrefix);

/// The append id of an `appends.<id>` op field, or null.
String? appendId(String field) => _suffix(field, appendPrefix);

/// The row map key and member id a field family op lives under, or null for a
/// plain field (ops.ts familyOf).
({String key, String id})? familyOf(String entity, String field) {
  final fid = entity == 'task' ? fieldValueId(field) : null;
  if (fid != null) return (key: 'fields', id: fid);
  final aid = entity == 'task' || entity == 'note' ? appendId(field) : null;
  if (aid != null) return (key: 'appends', id: aid);
  final account = entity == 'comment' ? reactionAccount(field) : null;
  return account != null ? (key: 'reactions', id: account) : null;
}

/// A row's value of an op field (ops.ts readField).
Object? readField(String entity, Map<String, Object?> row, String field) {
  final fam = familyOf(entity, field);
  if (fam == null) return row[field];
  return (row[fam.key] as Map?)?[fam.id];
}

Object? _copy(Object? v) => switch (v) {
      final List<Object?> l => [for (final e in l) _copy(e)],
      final Map<Object?, Object?> m => {for (final e in m.entries) e.key as String: _copy(e.value)},
      _ => v,
    };

/// A fresh, mutable copy of an entity's defaults (empty for an unknown entity).
Map<String, Object?> defaultsOf(String entity) =>
    (_copy(opDefaults[entity] ?? const <String, Object?>{}) as Map<String, Object?>);

/// Builds the row of [entity] [entityId] from its registers: defaults first,
/// then every stored field (families folded into their map).
Map<String, Object?> buildRow(String entity, String entityId, Map<String, StoredField> fields) {
  final row = defaultsOf(entity)..['id'] = entityId;
  for (final e in fields.entries) {
    final fam = familyOf(entity, e.key);
    if (fam == null) {
      row[e.key] = e.value.value;
    } else {
      final map = Map<String, Object?>.from((row[fam.key] as Map?) ?? const {});
      map[fam.id] = e.value.value;
      row[fam.key] = map;
    }
  }
  return row;
}

/// Whether a row is a tombstone (`deleted_at` set).
bool isDeleted(Map<String, Object?> row) => row['deleted_at'] != null;

/// Builds every row of [entity]; tombstones are left out unless [includeDeleted].
List<Map<String, Object?>> buildRows(
  String entity,
  Map<String, Map<String, StoredField>> byId, {
  bool includeDeleted = false,
}) {
  final out = <Map<String, Object?>>[];
  for (final e in byId.entries) {
    final row = buildRow(entity, e.key, e.value);
    if (includeDeleted || !isDeleted(row)) out.add(row);
  }
  return out;
}

/// One row read from [store], or null when no op for it was ever applied.
/// Tombstones are returned (a deleted row is still addressable by id).
Future<Map<String, Object?>?> loadRow(SyncStore store, String entity, String entityId) async {
  final fields = await store.readRow(entity, entityId);
  return fields.isEmpty ? null : buildRow(entity, entityId, fields);
}

/// Every live row of [entity] in [store] (tombstones only with [includeDeleted]).
Future<List<Map<String, Object?>>> loadRows(SyncStore store, String entity, {bool includeDeleted = false}) async =>
    buildRows(entity, await store.readEntity(entity), includeDeleted: includeDeleted);

// --- typed views ---

/// A typed view over a materialized row; [data] stays the source of truth.
abstract class EntityRow {
  final Map<String, Object?> data;

  const EntityRow(this.data);

  String get id => data['id'] as String;
  num get position => _num('position') ?? 0;
  int get createdAt => _int('created_at') ?? 0;
  int? get deletedAt => _int('deleted_at');
  bool get isDeleted => deletedAt != null;

  String _str(String k) => data[k] as String? ?? '';
  String? _strOrNull(String k) => data[k] as String?;
  bool _bool(String k) => data[k] as bool? ?? false;
  num? _num(String k) => data[k] as num?;
  int? _int(String k) => (data[k] as num?)?.toInt();
  List<String> _strings(String k) => [for (final v in (data[k] as List?) ?? const []) v as String];

  @override
  String toString() => '$runtimeType($data)';
}

class Project extends EntityRow {
  const Project(super.data);
  String get name => _str('name');
  String get color => _str('color');
  bool get archived => _bool('archived');
  String? get parentId => _strOrNull('parent_id');
  String? get icon => _strOrNull('icon');
  String get description => _str('description');
  String get notesDoc => _str('notes_doc');
  String? get workspaceId => _strOrNull('workspace_id');
}

class Task extends EntityRow {
  const Task(super.data);
  String get title => _str('title');
  String get description => _str('description');
  String get notesDoc => _str('notes_doc');
  String? get projectId => _strOrNull('project_id');
  String? get parentId => _strOrNull('parent_id');
  String? get sectionId => _strOrNull('section_id');
  int get priority => _int('priority') ?? 4;

  /// `{"date": "YYYY-MM-DD", "time"?: "HH:MM", "tz"?: "Area/City"}` or null.
  Map<String, Object?>? get due => (data['due'] as Map?)?.cast<String, Object?>();
  List<String> get labels => _strings('labels');
  int? get completedAt => _int('completed_at');
  bool get isCompleted => completedAt != null;
  int? get estimateMinutes => _int('estimate_minutes');
  String? get deadline => _strOrNull('deadline');

  /// null (anytime), "someday" or "YYYY-MM-DD".
  String? get start => _strOrNull('start');
  bool get evening => _bool('evening');
  String? get recurrence => _strOrNull('recurrence');
  String? get seriesId => _strOrNull('series_id');
  String? get occurrenceDate => _strOrNull('occurrence_date');
  String? get assigneeId => _strOrNull('assignee_id');
  List<String> get blockedBy => _strings('blocked_by');
  bool get habit => _bool('habit');
  bool get skipped => _bool('skipped');

  /// Custom field values by definition id (`fields.<id>` ops).
  Map<String, Object?> get fields => ((data['fields'] as Map?) ?? const {}).cast<String, Object?>();
}

class Label extends EntityRow {
  const Label(super.data);
  String get name => _str('name');
  String get color => _str('color');
  String? get workspaceId => _strOrNull('workspace_id');
}

class Section extends EntityRow {
  const Section(super.data);
  String get name => _str('name');
  String get projectId => _str('project_id');
  String? get color => _strOrNull('color');
  String? get icon => _strOrNull('icon');
}

class Reminder extends EntityRow {
  const Reminder(super.data);
  String get taskId => _str('task_id');

  /// "relative", "absolute", "deadline", "arrive" or "leave".
  String get kind => _str('kind');
  int? get offsetMinutes => _int('offset_minutes');
  int? get fireAt => _int('fire_at');
  int? get deliveredAt => _int('delivered_at');
  int? get dismissedAt => _int('dismissed_at');
  int? get radiusM => _int('radius_m');
}

/// The account's preferences: one row, id "me".
class UserPrefs extends EntityRow {
  const UserPrefs(super.data);

  /// The default preferences, for an account that has written none.
  factory UserPrefs.defaults() => UserPrefs(defaultsOf('user_prefs')..['id'] = 'me');

  String get dateFormat => _str('date_format');
  String get timeFormat => _str('time_format');
  String get weekStart => _str('week_start');
  String get dayStart => _str('day_start');
  String get themeMode => _str('theme_mode');
  String get themeAccent => _str('theme_accent');
  String get language => _str('language');

  /// Any preference by its op field name.
  Object? operator [](String field) => data[field];
}

/// Typed loaders for the MVP entities (live rows only unless [includeDeleted]).
Future<List<Task>> loadTasks(SyncStore s, {bool includeDeleted = false}) async =>
    [for (final r in await loadRows(s, 'task', includeDeleted: includeDeleted)) Task(r)];
Future<List<Project>> loadProjects(SyncStore s, {bool includeDeleted = false}) async =>
    [for (final r in await loadRows(s, 'project', includeDeleted: includeDeleted)) Project(r)];
Future<List<Label>> loadLabels(SyncStore s, {bool includeDeleted = false}) async =>
    [for (final r in await loadRows(s, 'label', includeDeleted: includeDeleted)) Label(r)];
Future<List<Section>> loadSections(SyncStore s, {bool includeDeleted = false}) async =>
    [for (final r in await loadRows(s, 'section', includeDeleted: includeDeleted)) Section(r)];
Future<List<Reminder>> loadReminders(SyncStore s, {bool includeDeleted = false}) async =>
    [for (final r in await loadRows(s, 'reminder', includeDeleted: includeDeleted)) Reminder(r)];

/// The account's preferences, defaults when none were ever written.
Future<UserPrefs> loadUserPrefs(SyncStore s) async {
  final row = await loadRow(s, 'user_prefs', 'me');
  return row == null ? UserPrefs.defaults() : UserPrefs(row);
}
