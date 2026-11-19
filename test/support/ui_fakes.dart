// Fakes for widget tests of the app shell, setup and sign-in.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opentodo_flutter/core/hlc.dart';
import 'package:opentodo_flutter/data/account.dart';
import 'package:opentodo_flutter/data/api.dart';
import 'package:opentodo_flutter/data/secure_store.dart';
import 'package:opentodo_flutter/data/store.dart';
import 'package:opentodo_flutter/data/sync_engine.dart';
import 'package:opentodo_flutter/ui/bootstrap.dart';
import 'package:opentodo_flutter/ui/sync_controller.dart';

/// A sync controller whose status the test sets.
class FakeSync implements SyncController {
  final _c = StreamController<SyncStatus>.broadcast(sync: true);
  @override
  SyncStatus status = const SyncStatus();
  int runs = 0;

  void emit(SyncStatus s) {
    status = s;
    _c.add(s);
  }

  @override
  Stream<SyncStatus> get statusStream => _c.stream;

  @override
  Future<void> syncNow() async => runs++;
}

AccountState testAccount({String email = 'me@a.test'}) => AccountState(
      serverUrl: 'https://a.test',
      userId: 'u1',
      email: email,
      encrypted: false,
      keyVersion: 0,
      deviceId: 'flutter:test',
    );

AppSession fakeSession(FakeSync sync, [AccountState? account]) => AppSession(
      account: account ?? testAccount(),
      store: MemoryStore(),
      hlc: Hlc(),
      sync: sync,
    );

http.Response jsonRes(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});

/// The sign-in routes of a server: password, optional second factor,
/// configurable failures.
class FakeAuthServer {
  String password = 'pw';
  bool mfa = false;
  String code = '123456';

  /// When set, `auth/login` answers with this response.
  http.Response? loginOverride;
  final List<String> calls = [];

  MockClient get client => MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        switch ('${req.method} ${req.url.path}') {
          case 'POST /api/v1/auth/login':
            final o = loginOverride;
            if (o != null) return o;
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            if (body['password'] != password) {
              return jsonRes({
                'error': {'code': 'invalid_credentials', 'message': 'wrong'}
              }, status: 401);
            }
            if (mfa) return jsonRes({'mfaRequired': true, 'challenge': 'ch1'});
            return jsonRes({'user': {}}, headers: {'set-cookie': 'opentodo_session=s; Path=/'});
          case 'POST /api/v1/auth/mfa':
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            if (body['code'] != code) {
              return jsonRes({
                'error': {'code': 'mfa_code_invalid', 'message': 'wrong code'}
              }, status: 401);
            }
            return jsonRes({'user': {}}, headers: {'set-cookie': 'opentodo_session=s; Path=/'});
          case 'POST /api/v1/tokens':
            return jsonRes({'token': {'id': 'tok-1'}, 'secret': 'ot_secret'}, status: 201);
          case 'GET /api/v1/me':
            return jsonRes({
              'user': {'id': 'u1', 'email': 'me@a.test'},
              'encryption': {'enabled': false, 'keyVersion': 0},
            });
        }
        return jsonRes({'error': {'code': 'not_found', 'message': ''}}, status: 404);
      });
}

/// App dependencies over fakes: a memory secure store, [server] for the
/// account routes, [health] for the setup check and [sync] for every session.
class FakeApp {
  final secure = MemorySecureStore();
  final server = FakeAuthServer();
  final sync = FakeSync();
  final List<String> healthChecked = [];
  Future<HealthInfo> Function(String origin)? health;

  AccountManager accounts() => AccountManager(
        store: secure,
        apiFactory: (url) =>
            ApiClient(url, client: server.client, maxAttempts: 1, sleep: (_) async {}),
        newDeviceId: () => 'flutter:test',
      );

  AppDeps deps() => AppDeps(
        accounts: accounts(),
        openSession: (_, account) async => fakeSession(sync, account),
        healthCheck: (origin) async {
          healthChecked.add(origin);
          final h = health;
          return h != null ? h(origin) : HealthInfo(status: 'ok', version: '1.5.0');
        },
      );
}
