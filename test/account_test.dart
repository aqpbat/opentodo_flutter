import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opentodo_flutter/data/account.dart';
import 'package:opentodo_flutter/data/api.dart';
import 'package:opentodo_flutter/data/secure_store.dart';

http.Response jsonRes(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});

/// A fake server per base URL: users by server, optional second factor.
class FakeBackend {
  final List<http.Request> requests = [];
  bool mfa = false;
  bool encrypted = false;
  String userId = 'u1';
  bool online = true;

  MockClient get client => MockClient((req) async {
        if (!online) throw http.ClientException('offline');
        requests.add(req);
        switch ('${req.method} ${req.url.path}') {
          case 'POST /api/v1/auth/login':
            if (mfa) return jsonRes({'mfaRequired': true, 'challenge': 'ch1'});
            return jsonRes({'user': {}},
                headers: {'set-cookie': 'opentodo_session=s-${req.url.host}; Path=/'});
          case 'POST /api/v1/auth/mfa':
            return jsonRes({'user': {}},
                headers: {'set-cookie': 'opentodo_session=s-${req.url.host}; Path=/'});
          case 'POST /api/v1/tokens':
            return jsonRes({'token': {'id': 'tok-1'}, 'secret': 'ot_${req.url.host}'},
                status: 201);
          case 'GET /api/v1/me':
            return jsonRes({
              'user': {'id': userId, 'email': 'me@${req.url.host}'},
              'encryption': {'enabled': encrypted, 'keyVersion': encrypted ? 1 : 0},
            });
          case 'DELETE /api/v1/tokens/tok-1':
          case 'POST /api/v1/auth/logout':
            return http.Response('', 204);
        }
        return jsonRes({'error': {'code': 'not_found', 'message': ''}}, status: 404);
      });
}

class Harness {
  final store = MemorySecureStore();
  final backend = FakeBackend();
  final log = <String>[];
  var deviceCounter = 0;

  AccountManager manager() => AccountManager(
        store: store,
        apiFactory: (url) => ApiClient(url, client: backend.client, sleep: (_) async {}),
        stopSync: () async => log.add('stopSync'),
        clearLocalData: () async => log.add('clearLocalData'),
        newDeviceId: () => 'flutter:dev-${++deviceCounter}',
      );
}

void main() {
  test('password sign-in saves the session; a new manager restores it', () async {
    final h = Harness();
    final m = h.manager();
    final step = await m.signInWithPassword(
        serverUrl: 'https://a.test/', email: 'me@a.test', password: 'pw');
    final state = (step as SignedIn).account;
    expect(state.serverUrl, 'https://a.test');
    expect(state.userId, 'u1');
    expect(state.email, 'me@a.test');
    expect(state.deviceId, 'flutter:dev-1');
    expect(h.store.values[SecureKeys.token], 'ot_a.test');
    expect(h.store.values[SecureKeys.session], 'opentodo_session=s-a.test');
    await m.saveDek(Uint8List.fromList(List.filled(32, 7)));

    final again = h.manager();
    final restored = await again.restore();
    expect(restored?.toJson(), state.toJson());
    expect(again.api?.token, 'ot_a.test');
    expect(again.api?.sessionCookie, 'opentodo_session=s-a.test');
    expect(again.dek, Uint8List.fromList(List.filled(32, 7)));
  });

  test('restore without a saved session is signed out', () async {
    final h = Harness();
    expect(await h.manager().restore(), isNull);
  });

  test('MFA sign-in finishes with completeMfa', () async {
    final h = Harness()..backend.mfa = true;
    final m = h.manager();
    final step = await m.signInWithPassword(
        serverUrl: 'https://a.test', email: 'x', password: 'y');
    expect(step, isA<MfaRequired>());
    expect((step as MfaRequired).challenge, 'ch1');
    expect(m.signedIn, isFalse);
    final state = await m.completeMfa(code: '123456');
    expect(state.userId, 'u1');
    expect(m.signedIn, isTrue);
    final mfaReq = h.backend.requests.firstWhere((r) => r.url.path == '/api/v1/auth/mfa');
    expect(jsonDecode(mfaReq.body), {'challenge': 'ch1', 'code': '123456'});
    await expectLater(m.completeMfa(code: '1'), throwsStateError);
  });

  test('token sign-in reads encryption state from me', () async {
    final h = Harness()..backend.encrypted = true;
    final state = await h.manager().signInWithToken('https://a.test', 'ot_given');
    expect(state.encrypted, isTrue);
    expect(state.keyVersion, 1);
    expect(h.store.values[SecureKeys.token], 'ot_given');
    expect(h.store.values.containsKey(SecureKeys.session), isFalse);
  });

  test('sign-out stops sync, revokes, clears the database and every secret', () async {
    final h = Harness();
    final m = h.manager();
    await m.signInWithPassword(serverUrl: 'https://a.test', email: 'x', password: 'y');
    await m.saveDek(Uint8List(32));
    final epoch = m.epoch;
    h.backend.requests.clear();

    await m.signOut();

    expect(h.log, ['stopSync', 'clearLocalData']);
    expect(m.epoch, greaterThan(epoch));
    expect(h.store.values, isEmpty);
    expect(m.signedIn, isFalse);
    expect(m.api, isNull);
    expect(m.dek, isNull);
    final [revoke, logout] = h.backend.requests;
    expect('${revoke.method} ${revoke.url.path}', 'DELETE /api/v1/tokens/tok-1');
    expect(revoke.headers['Authorization'], 'Bearer ot_a.test');
    expect(revoke.headers.containsKey('Cookie'), isFalse);
    expect(logout.url.path, '/api/v1/auth/logout');
    expect(logout.headers['Cookie'], 'opentodo_session=s-a.test');
    expect(await h.manager().restore(), isNull);
  });

  test('sign-out offline still wipes everything', () async {
    final h = Harness();
    final m = h.manager();
    await m.signInWithPassword(serverUrl: 'https://a.test', email: 'x', password: 'y');
    h.backend.online = false;
    await m.signOut(remoteTimeout: const Duration(milliseconds: 200));
    expect(h.log, ['stopSync', 'clearLocalData']);
    expect(h.store.values, isEmpty);
    expect(m.signedIn, isFalse);
  });

  test('switching server resets local data; device id is new after the wipe', () async {
    final h = Harness();
    final m = h.manager();
    final a = await m.signInWithToken('https://a.test', 'ot_a');
    expect(h.log, isEmpty);

    // Same server, same user again: nothing wiped, same device id.
    final a2 = await m.signInWithToken('https://a.test', 'ot_a2');
    expect(h.log, isEmpty);
    expect(a2.deviceId, a.deviceId);

    final b = await m.signInWithToken('https://b.test', 'ot_b');
    expect(h.log, ['stopSync', 'clearLocalData']);
    expect(b.serverUrl, 'https://b.test');
    expect(b.deviceId, isNot(a.deviceId));
    expect(h.store.values[SecureKeys.token], 'ot_b');
  });

  test('refresh follows encryption being turned off and drops the DEK', () async {
    final h = Harness()..backend.encrypted = true;
    final m = h.manager();
    await m.signInWithToken('https://a.test', 'ot_a');
    await m.saveDek(Uint8List(32));
    h.backend.encrypted = false;
    final s = await m.refresh();
    expect(s.encrypted, isFalse);
    expect(m.dek, isNull);
    expect(h.store.values.containsKey(SecureKeys.dek), isFalse);
    final saved = jsonDecode(h.store.values[SecureKeys.account]!) as Map;
    expect(saved['encrypted'], false);
  });
}
