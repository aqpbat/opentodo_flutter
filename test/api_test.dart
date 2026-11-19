import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opentodo_flutter/core/e2ee.dart' show KeyRecord;
import 'package:opentodo_flutter/data/api.dart';

const base = 'https://todo.test';

/// A scripted fake server: records every request, answers from [handler].
class FakeServer {
  final List<http.Request> requests = [];
  final Future<http.Response> Function(http.Request req) handler;
  FakeServer(this.handler);

  MockClient get client => MockClient((req) async {
        requests.add(req);
        return handler(req);
      });
}

http.Response jsonRes(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});

http.Response errRes(int status, String code, {Map<String, String>? headers}) =>
    jsonRes({'error': {'code': code, 'message': '$code!'}}, status: status, headers: headers);

ApiClient makeClient(FakeServer s, {List<Duration>? sleeps, int maxAttempts = 4}) =>
    ApiClient('$base/',
        client: s.client,
        maxAttempts: maxAttempts,
        backoff: Backoff(random: Random(1)),
        sleep: (d) async => sleeps?.add(d));

const sessionCookie =
    'opentodo_session=sess123; Path=/; Expires=Thu, 01 Jan 2099 00:00:00 GMT; HttpOnly; SameSite=Lax';

void main() {
  group('sign-in flow', () {
    test('login → cookie → POST tokens → me with bearer → logout', () async {
      final s = FakeServer((req) async {
        switch ('${req.method} ${req.url.path}') {
          case 'POST /api/v1/auth/login':
            return jsonRes({'user': {'id': 'u1'}}, headers: {'set-cookie': sessionCookie});
          case 'POST /api/v1/tokens':
            return jsonRes({'token': {'id': 't1', 'name': 'flutter'}, 'secret': 'ot_secret'},
                status: 201);
          case 'GET /api/v1/me':
            return jsonRes({
              'user': {'id': 'u1', 'email': 'a@b.c'},
              'encryption': {'enabled': true, 'keyVersion': 2},
              'auth': {'method': 'token', 'scope': 'full'},
            });
          case 'POST /api/v1/auth/logout':
            return http.Response('', 204);
        }
        return errRes(404, 'not_found');
      });
      final api = makeClient(s);
      expect(api.baseUrl, base);

      final login = await api.login('a@b.c', 'pw');
      expect(login.mfaRequired, isFalse);
      expect(api.hasSession, isTrue);
      expect(api.sessionCookie, 'opentodo_session=sess123');

      final created = await api.createToken('flutter');
      expect(created.secret, 'ot_secret');
      expect(created.id, 't1');
      api.token = created.secret;

      final me = await api.me();
      expect(me.userId, 'u1');
      expect(me.email, 'a@b.c');
      expect(me.encryptionEnabled, isTrue);
      expect(me.keyVersion, 2);
      expect(me.authScope, 'full');

      await api.logout();
      expect(api.hasSession, isFalse);

      final [loginReq, tokenReq, meReq, logoutReq] = s.requests;
      expect(jsonDecode(loginReq.body), {'email': 'a@b.c', 'password': 'pw'});
      expect(loginReq.headers['Content-Type'], startsWith('application/json'));
      expect(loginReq.headers.containsKey('Cookie'), isFalse);

      // Credential write: cookie, JSON, no Origin, no bearer.
      expect(tokenReq.headers['Cookie'], 'opentodo_session=sess123');
      expect(tokenReq.headers['Content-Type'], startsWith('application/json'));
      expect(tokenReq.headers.containsKey('Origin'), isFalse);
      expect(tokenReq.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(tokenReq.body), {'name': 'flutter'});

      expect(meReq.headers['Authorization'], 'Bearer ot_secret');
      expect(logoutReq.headers['Cookie'], 'opentodo_session=sess123');
      expect(logoutReq.headers.containsKey('Origin'), isFalse);
    });

    test('MFA branch: no cookie at login, cookie after auth/mfa', () async {
      final s = FakeServer((req) async {
        switch (req.url.path) {
          case '/api/v1/auth/login':
            return jsonRes({'mfaRequired': true, 'challenge': 'Zk3', 'expiresAt': 1760000300000});
          case '/api/v1/auth/mfa':
            final b = jsonDecode(req.body) as Map;
            if (b['code'] != '492039') return errRes(401, 'mfa_code_invalid');
            return jsonRes({'user': {'id': 'u1'}}, headers: {
              'set-cookie': '$sessionCookie,ot_trust=tr1; Path=/api/v1/auth; Max-Age=2592000'
            });
          case '/api/v1/tokens':
            return jsonRes({'token': {'id': 't1'}, 'secret': 'ot_x'}, status: 201);
        }
        return errRes(404, 'not_found');
      });
      final api = makeClient(s);
      final login = await api.login('a@b.c', 'pw');
      expect(login.mfaRequired, isTrue);
      expect(login.challenge, 'Zk3');
      expect(login.expiresAt, 1760000300000);
      expect(api.hasSession, isFalse);

      await expectLater(api.mfa('Zk3', code: '000000'), throwsA(isA<UnauthorizedError>()));
      expect(api.hasSession, isFalse);

      final user = await api.mfa('Zk3', code: '492039', remember: true);
      expect(user?['id'], 'u1');
      expect(jsonDecode(s.requests.last.body),
          {'challenge': 'Zk3', 'code': '492039', 'remember': true});
      expect(api.sessionCookie, 'opentodo_session=sess123; ot_trust=tr1');

      await api.createToken('flutter');
      expect(s.requests.last.headers['Cookie'], contains('opentodo_session=sess123'));
    });

    test('expired Set-Cookie removes the cookie', () async {
      var n = 0;
      final s = FakeServer((req) async {
        n++;
        return jsonRes({'user': {}},
            headers: {'set-cookie': n == 1 ? sessionCookie : 'opentodo_session=; Path=/; Max-Age=0'});
      });
      final api = makeClient(s);
      await api.login('a', 'b');
      expect(api.hasSession, isTrue);
      await api.login('a', 'b');
      expect(api.hasSession, isFalse);
    });
  });

  group('errors', () {
    test('401 → UnauthorizedError with the envelope', () async {
      final s = FakeServer((_) async => errRes(401, 'invalid_credentials'));
      final api = makeClient(s);
      try {
        await api.login('a', 'b');
        fail('expected an error');
      } on UnauthorizedError catch (e) {
        expect(e.status, 401);
        expect(e.code, 'invalid_credentials');
        expect(e.message, 'invalid_credentials!');
      }
      expect(s.requests, hasLength(1)); // not retried
    });

    test('non-envelope error keeps the status as code', () async {
      final s = FakeServer((_) async => http.Response('<html>oops</html>', 500));
      final api = makeClient(s)..token = 't';
      await expectLater(
          api.me(), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'http_500')));
    });

    test('403 insufficient_scope is not retried', () async {
      final s = FakeServer((_) async => errRes(403, 'insufficient_scope'));
      final api = makeClient(s)..token = 't';
      await expectLater(api.exchange({'device': 'd'}),
          throwsA(isA<ApiError>().having((e) => e.code, 'code', 'insufficient_scope')));
      expect(s.requests, hasLength(1));
    });

    test('bearer route without a token is a StateError, nothing sent', () async {
      final s = FakeServer((_) async => jsonRes({}));
      final api = makeClient(s);
      await expectLater(api.exchange({}), throwsStateError);
      expect(s.requests, isEmpty);
    });

    test('network failure retried, then NetworkError', () async {
      var calls = 0;
      final api = ApiClient(base,
          client: MockClient((_) async {
            calls++;
            throw http.ClientException('down');
          }),
          maxAttempts: 3,
          sleep: (_) async {})
        ..token = 't';
      await expectLater(api.me(), throwsA(isA<NetworkError>()));
      expect(calls, 3);
    });
  });

  group('429 backoff', () {
    test('retries with growing jittered delays, then succeeds', () async {
      var n = 0;
      final s = FakeServer((_) async {
        n++;
        if (n < 3) return errRes(429, 'rate_limited');
        return jsonRes({'ops': [], 'cursor': 5, 'hasMore': false});
      });
      final sleeps = <Duration>[];
      final api = makeClient(s, sleeps: sleeps)..token = 't';
      final page = await api.exchange({'device': 'flutter:x', 'cursor': 0, 'ops': []});
      expect(page['cursor'], 5);
      expect(s.requests, hasLength(3));
      expect(sleeps, hasLength(2));
      // attempt 0: [0.5 s, 1 s], attempt 1: [1 s, 2 s]
      expect(sleeps[0].inMilliseconds, inInclusiveRange(500, 1000));
      expect(sleeps[1].inMilliseconds, inInclusiveRange(1000, 2000));
    });

    test('honours Retry-After when longer than the backoff', () async {
      var n = 0;
      final s = FakeServer((_) async =>
          n++ == 0 ? errRes(429, 'rate_limited', headers: {'retry-after': '7'}) : jsonRes({}));
      final sleeps = <Duration>[];
      final api = makeClient(s, sleeps: sleeps)..token = 't';
      await api.exchange({});
      expect(sleeps, [const Duration(seconds: 7)]);
    });

    test('gives up with RateLimitedError after maxAttempts', () async {
      final s = FakeServer((_) async => errRes(429, 'rate_limited'));
      final sleeps = <Duration>[];
      final api = makeClient(s, sleeps: sleeps, maxAttempts: 3)..token = 't';
      await expectLater(api.exchange({}), throwsA(isA<RateLimitedError>()));
      expect(s.requests, hasLength(3));
      expect(sleeps, hasLength(2));
    });

    test('a long lock (Retry-After > 30 s) is not waited out', () async {
      final s = FakeServer(
          (_) async => errRes(429, 'account_locked', headers: {'retry-after': '900'}));
      final sleeps = <Duration>[];
      final api = makeClient(s, sleeps: sleeps);
      await expectLater(
          api.login('a', 'b'),
          throwsA(isA<RateLimitedError>()
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 900))));
      expect(sleeps, isEmpty);
    });

    test('Backoff caps at 30 s and stays within [d/2, d]', () {
      final b = Backoff(random: Random(3));
      for (var i = 0; i < 12; i++) {
        final full = min(1000 * (1 << i), 30000);
        final d = b.delay(i).inMilliseconds;
        expect(d, inInclusiveRange(full ~/ 2, full));
      }
      expect(b.delay(100).inMilliseconds, lessThanOrEqualTo(30000));
    });
  });

  group('credential separation', () {
    test('cookie never leaks into bearer requests', () async {
      final s = FakeServer((req) async {
        if (req.url.path == '/api/v1/auth/login') {
          return jsonRes({'user': {}}, headers: {'set-cookie': sessionCookie});
        }
        // A bearer answer that tries to set a cookie must not enter the jar.
        return jsonRes({'ok': true}, headers: {'set-cookie': 'evil=1; Path=/'});
      });
      final api = makeClient(s);
      await api.login('a', 'b');
      api.token = 'ot_t';
      await api.me();
      await api.exchange({'device': 'd'});
      await api.send('GET', '/api/v1/tasks', query: {'project_id': 'p'});
      await api.getKeyRecord().catchError((_) => null);
      for (final r in s.requests.skip(1)) {
        expect(r.headers.containsKey('Cookie'), isFalse, reason: r.url.path);
        expect(r.headers['Authorization'], 'Bearer ot_t');
      }
      expect(s.requests[3].url.query, 'project_id=p');
      expect(api.sessionCookie, 'opentodo_session=sess123');
    });

    test('key record: GET with bearer, PUT with the session cookie', () async {
      final record = {
        'version': 1,
        'kdf': 1,
        'salt': 'AQEBAQEBAQEBAQEBAQEBAQ',
        'iterations': 600000,
        'wrappedByPassphrase': 'wp',
        'wrappedByRecovery': 'wr',
      };
      final s = FakeServer((req) async {
        if (req.method == 'GET') return errRes(404, 'encryption_disabled');
        return jsonRes({'keys': {...record, 'createdAt': 1, 'updatedAt': 1}}, status: 201);
      });
      final api = makeClient(s)
        ..token = 'ot_t'
        ..sessionCookie = 'opentodo_session=sess123';
      expect(await api.getKeyRecord(), isNull);
      final stored = await api.putKeyRecord(KeyRecord.fromJson(record));
      expect(stored.createdAt, 1);
      final [get, put] = s.requests;
      expect(get.headers['Authorization'], 'Bearer ot_t');
      expect(get.headers.containsKey('Cookie'), isFalse);
      expect(put.method, 'PUT');
      expect(put.url.path, '/api/v1/encryption/keys');
      expect(put.headers['Cookie'], 'opentodo_session=sess123');
      expect(put.headers.containsKey('Authorization'), isFalse);
      expect(put.headers.containsKey('Origin'), isFalse);
      expect(jsonDecode(put.body), record);
    });

    test('PUT key record conflict surfaces encryption_conflict', () async {
      final s = FakeServer((_) async => errRes(409, 'encryption_conflict'));
      final api = makeClient(s)..sessionCookie = 'opentodo_session=s';
      await expectLater(
          api.putKeyRecord(KeyRecord(
              version: 1, kdf: 1, salt: 's', iterations: 600000,
              wrappedByPassphrase: 'a', wrappedByRecovery: 'b')),
          throwsA(isA<ApiError>().having((e) => e.code, 'code', 'encryption_conflict')));
    });
  });

  group('health', () {
    test('uses /api/v1/health', () async {
      final s = FakeServer((_) async => jsonRes({'status': 'ok', 'version': '1.5.0', 'app_sign_in': true}));
      final h = await makeClient(s).health();
      expect(h.version, '1.5.0');
      expect(h.appSignIn, isTrue);
      expect(s.requests.single.url.path, '/api/v1/health');
      expect(s.requests.single.headers.containsKey('Authorization'), isFalse);
    });

    test('falls back to /healthz on 404 or non-JSON', () async {
      for (final first in [errRes(404, 'not_found'), http.Response('OK', 200)]) {
        final s = FakeServer((req) async => req.url.path == '/api/v1/health'
            ? first
            : jsonRes({'status': 'ok', 'version': '1.5.0'}));
        final h = await makeClient(s).health();
        expect(h.status, 'ok');
        expect(s.requests.map((r) => r.url.path), ['/api/v1/health', '/healthz']);
      }
    });
  });

  test('exchange posts JSON to /api/v1/sync', () async {
    final s = FakeServer((_) async => jsonRes({'cursor': 1}));
    final api = makeClient(s)..token = 't';
    await api.exchange({'device': 'flutter:1', 'cursor': 0, 'ops': [], 'features': ['invalid_ops']});
    final r = s.requests.single;
    expect(r.method, 'POST');
    expect(r.url.toString(), '$base/api/v1/sync');
    expect((jsonDecode(r.body) as Map)['features'], ['invalid_ops']);
  });

  test('splitSetCookie keeps Expires dates intact', () {
    expect(splitSetCookie('a=1; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/,b=2'),
        ['a=1; Expires=Thu, 01 Jan 2099 00:00:00 GMT; Path=/', 'b=2']);
  });
}
