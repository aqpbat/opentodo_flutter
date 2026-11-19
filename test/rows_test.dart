import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/schema_generated.dart';
import 'package:opentodo_flutter/data/rows.dart';
import 'package:opentodo_flutter/data/store.dart';

import 'store_contract.dart';

void main() {
  late MemoryStore store;
  setUp(() => store = MemoryStore());

  group('defaults of every MVP entity', () {
    test('a row with no stored fields is exactly the defaults plus id', () {
      for (final entity in ['task', 'project', 'label', 'section', 'reminder', 'user_prefs']) {
        final row = buildRow(entity, 'x', const {});
        expect(row, {...opDefaults[entity]!, 'id': 'x'}, reason: entity);
      }
    });

    test('task defaults read through the typed view', () async {
      await store.applyOps([op('title', 'Buy milk', 1, 'd')]);
      final t = (await loadTasks(store)).single;
      expect(t.id, 't1');
      expect(t.title, 'Buy milk');
      expect(t.description, '');
      expect(t.priority, 4);
      expect(t.projectId, isNull);
      expect(t.due, isNull);
      expect(t.labels, isEmpty);
      expect(t.position, 0);
      expect(t.createdAt, 0);
      expect(t.isCompleted, isFalse);
      expect(t.isDeleted, isFalse);
      expect(t.evening, isFalse);
      expect(t.blockedBy, isEmpty);
      expect(t.fields, isEmpty);
      expect(t.notesDoc, '');
    });

    test('project defaults', () async {
      await store.applyOps([op('name', 'Home', 1, 'd', entity: 'project', entityId: 'p')]);
      final p = (await loadProjects(store)).single;
      expect(p.name, 'Home');
      expect(p.color, '#64748b');
      expect(p.archived, isFalse);
      expect(p.parentId, isNull);
      expect(p.description, '');
    });

    test('label defaults', () async {
      await store.applyOps([op('name', 'urgent', 1, 'd', entity: 'label', entityId: 'l')]);
      final l = (await loadLabels(store)).single;
      expect(l.name, 'urgent');
      expect(l.color, '#64748b');
      expect(l.position, 0);
    });

    test('section defaults', () async {
      await store.applyOps([op('name', 'Todo', 1, 'd', entity: 'section', entityId: 's')]);
      final s = (await loadSections(store)).single;
      expect(s.name, 'Todo');
      expect(s.projectId, '');
      expect(s.color, isNull);
    });

    test('reminder defaults', () async {
      await store.applyOps([op('task_id', 't1', 1, 'd', entity: 'reminder', entityId: 'r')]);
      final r = (await loadReminders(store)).single;
      expect(r.taskId, 't1');
      expect(r.kind, 'relative');
      expect(r.offsetMinutes, isNull);
      expect(r.fireAt, isNull);
      expect(r.radiusM, isNull);
    });

    test('user_prefs: defaults when never written, stored values over them', () async {
      final none = await loadUserPrefs(store);
      expect(none.id, 'me');
      expect(none.dateFormat, 'system');
      expect(none.themeAccent, 'emerald');
      expect(none['today_limit'], 0);
      await store.applyOps([op('theme_mode', 'dark', 1, 'd', entity: 'user_prefs', entityId: 'me')]);
      final prefs = await loadUserPrefs(store);
      expect(prefs.themeMode, 'dark');
      expect(prefs.language, 'system');
    });
  });

  group('materialization', () {
    test('stored fields override defaults; values keep their shape', () async {
      await store.applyOps([
        op('priority', 1, 1, 'd'),
        op('due', {'date': '2026-05-01', 'time': '10:00'}, 1, 'd'),
        op('labels', ['l1', 'l2'], 1, 'd'),
        op('position', 2.5, 1, 'd'),
        op('completed_at', 1760000000000, 1, 'd'),
      ]);
      final t = Task((await loadRow(store, 'task', 't1'))!);
      expect(t.priority, 1);
      expect(t.due, {'date': '2026-05-01', 'time': '10:00'});
      expect(t.labels, ['l1', 'l2']);
      expect(t.position, 2.5);
      expect(t.completedAt, 1760000000000);
      expect(t.isCompleted, isTrue);
    });

    test('families fold into their maps', () async {
      await store.applyOps([
        op('fields.size', 'L', 1, 'd'),
        op('fields.count', 3, 1, 'd'),
        op('appends.a1', 'more text', 1, 'd'),
        op('reactions.u1', ':+1:', 1, 'd', entity: 'comment', entityId: 'c1'),
        op('appends.n1', 'x', 1, 'd', entity: 'note', entityId: 'n'),
      ]);
      final task = (await loadRow(store, 'task', 't1'))!;
      expect(task['fields'], {'size': 'L', 'count': 3});
      expect(task['appends'], {'a1': 'more text'});
      expect(task.containsKey('fields.size'), isFalse);
      expect(readField('task', task, 'fields.count'), 3);
      expect(Task(task).fields['size'], 'L');
      expect((await loadRow(store, 'comment', 'c1'))!['reactions'], {'u1': ':+1:'});
      expect((await loadRow(store, 'note', 'n'))!['appends'], {'n1': 'x'});
    });

    test('a family prefix outside its entity, or with a bad id, stays a plain field', () {
      final row = buildRow('project', 'p', {
        'fields.x': StoredField.fromValue(1, ts: 1, device: 'd'),
      });
      expect(row['fields.x'], 1);
      final task = buildRow('task', 't', {
        'fields.bad id': StoredField.fromValue(1, ts: 1, device: 'd'),
      });
      expect(task['fields'], isEmpty);
      expect(task['fields.bad id'], 1);
    });

    test('defaults are copied, never shared between rows', () {
      final a = buildRow('task', 'a', const {});
      (a['labels'] as List).add('mutated');
      (a['fields'] as Map)['k'] = 1;
      final b = buildRow('task', 'b', const {});
      expect(b['labels'], isEmpty);
      expect(b['fields'], isEmpty);
      expect(opDefaults['task']!['labels'], isEmpty);
    });

    test('unknown fields of a newer server are kept', () {
      final row = buildRow('task', 't', {'future_field': StoredField.fromValue('v', ts: 1, device: 'd')});
      expect(row['future_field'], 'v');
    });

    test('an unknown entity builds a generic row', () {
      expect(buildRow('gadget', 'g', {'x': StoredField.fromValue(1, ts: 1, device: 'd')}), {'id': 'g', 'x': 1});
    });

    test('loadRow is null for a row never written', () async {
      expect(await loadRow(store, 'task', 'missing'), isNull);
    });
  });

  group('tombstones', () {
    setUp(() async {
      await store.applyOps([
        op('title', 'alive', 1, 'd', entityId: 'a'),
        op('title', 'gone', 1, 'd', entityId: 'b'),
        op('deleted_at', 1760000000000, 2, 'd', entityId: 'b'),
        op('title', 'restored', 1, 'd', entityId: 'c'),
        op('deleted_at', 5, 2, 'd', entityId: 'c'),
        op('deleted_at', null, 3, 'd', entityId: 'c'),
      ]);
    });

    test('deleted_at != null excludes the row from lists', () async {
      expect((await loadTasks(store)).map((t) => t.id).toSet(), {'a', 'c'});
      expect((await loadRows(store, 'task')).map((r) => r['id']).toSet(), {'a', 'c'});
    });

    test('includeDeleted lists tombstones; loadRow still finds them', () async {
      final all = await loadTasks(store, includeDeleted: true);
      expect(all.map((t) => t.id).toSet(), {'a', 'b', 'c'});
      expect(all.firstWhere((t) => t.id == 'b').isDeleted, isTrue);
      final b = (await loadRow(store, 'task', 'b'))!;
      expect(isDeleted(b), isTrue);
    });
  });
}
