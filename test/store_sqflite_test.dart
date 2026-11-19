import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/data/store.dart';
import 'package:opentodo_flutter/data/store_sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'store_contract.dart';

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  group('SqfliteStore (in memory)', () {
    runSyncStoreContract(() => SqfliteStore.open(factory, inMemoryDatabasePath));
  });

  group('SqfliteStore (file)', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('opentodo_store'));
    tearDown(() => dir.delete(recursive: true));

    test('state survives closing and reopening the database', () async {
      final path = p.join(dir.path, 'sync.db');
      var store = await SqfliteStore.open(factory, path);
      await store.applyOps([
        op('title', 'kept', 10, 'a'),
        op('fields.f1', 7, 10, 'a'),
      ]);
      await store.appendOutbox([op('title', 'kept', 10, 'a', id: 'q1')]);
      await store.setCursor(77);
      await store.setGeneration('gen-1');
      await store.setDeviceId('flutter:dev');
      await store.close();

      store = await SqfliteStore.open(factory, path);
      expect(await store.getField('task', 't1', 'title'), StoredField.fromValue('kept', ts: 10, device: 'a'));
      expect((await store.getField('task', 't1', 'fields.f1'))!.value, 7);
      expect((await store.readOutbox()).single.id, 'q1');
      expect(await store.cursor, 77);
      expect(await store.generation, 'gen-1');
      expect(await store.deviceId, 'flutter:dev');
      // The winner rule still holds against reopened registers.
      expect(await store.applyOps([op('title', 'stale', 9, 'z')]), isEmpty);
      await store.close();
    });

    test('a failing batch is atomic on disk', () async {
      final path = p.join(dir.path, 'atomic.db');
      var store = await SqfliteStore.open(factory, path);
      await store.applyOps([op('title', 'v1', 1, 'a')]);
      await expectLater(
        store.transaction((tx) async {
          await tx.applyOps([
            op('title', 'v2', 2, 'a'),
            op('name', 'p', 2, 'a', entity: 'project', entityId: 'p1'),
          ]);
          await tx.appendOutbox([op('title', 'v2', 2, 'a', id: 'x')]);
          throw StateError('crash mid-batch');
        }),
        throwsStateError,
      );
      await store.close();
      store = await SqfliteStore.open(factory, path);
      expect((await store.getField('task', 't1', 'title'))!.value, 'v1');
      expect(await store.readRow('project', 'p1'), isEmpty);
      expect(await store.outboxCount(), 0);
      await store.close();
    });

    test('the schema version is recorded', () async {
      final path = p.join(dir.path, 'v.db');
      final store = await SqfliteStore.open(factory, path);
      await store.close();
      final db = await factory.openDatabase(path);
      expect(await db.getVersion(), storeSchemaVersion);
      await db.close();
    });
  });
}
