// Inbox membership against the shared vectors of web/src/lib/inbox.vectors.json
// (copied unchanged), run the way web/src/lib/inbox.test.ts runs them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/inbox.dart';

void main() {
  final vectors = (jsonDecode(File('test/vectors/inbox.vectors.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  group('inbox.vectors.json', () {
    for (final v in vectors) {
      test(v['name'] as String, () {
        // The vector's parents chained as p0 (nearest), p1, ...; a missing parent
        // is p0 with no entry.
        final parents = ((v['parents'] as List?) ?? const []).cast<Map<String, dynamic>>();
        final byId = <String, Map<String, dynamic>>{
          for (var i = 0; i < parents.length; i++)
            'p$i': {...parents[i], 'parent_id': i + 1 < parents.length ? 'p${i + 1}' : null},
        };
        final hasParent = parents.isNotEmpty || v['parent_missing'] == true;
        final task = {...v['task'] as Map<String, dynamic>, 'parent_id': hasParent ? 'p0' : null};
        expect(isInboxTask(task, (id) => byId[id]), v['inbox']);
      });
    }
  });

  Map<String, dynamic> base(String id, String? parent, [Map<String, dynamic>? due]) => {
    'id': id,
    'parent_id': parent,
    'project_id': null,
    'due': due,
    'start': null,
    'completed_at': null,
    'deleted_at': null,
    'sector': '',
  };

  test('lists a scheduled parent out of the Inbox together with its unscheduled subtasks', () {
    final tasks = [
      base('parent', null, {'date': '2026-10-23'}),
      base('child', 'parent'),
      base('loose', null),
      base('loose-child', 'loose'),
    ];
    expect(inboxTasks(tasks).map((t) => t['id']), ['loose', 'loose-child']);
  });

  test('stops at a cycle in synced parents', () {
    final tasks = [base('a', 'b'), base('b', 'a')];
    expect(inboxTasks(tasks).map((t) => t['id']), ['a', 'b']);
  });

  test('completed_at 0 reads as open, like the web client', () {
    expect(isInboxTask({...base('a', null), 'completed_at': 0}), isTrue);
  });
}
