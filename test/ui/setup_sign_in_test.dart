import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opentodo_flutter/data/account.dart';
import 'package:opentodo_flutter/data/api.dart';
import 'package:opentodo_flutter/ui/app.dart';
import 'package:opentodo_flutter/ui/bootstrap.dart';
import 'package:opentodo_flutter/ui/screens/setup.dart';
import 'package:opentodo_flutter/ui/screens/sign_in.dart';
import 'package:opentodo_flutter/ui/server_address.dart';
import 'package:opentodo_flutter/ui/theme.dart';

import '../support/ui_fakes.dart';

Future<AppController> pumpRoot(WidgetTester tester, FakeApp app) async {
  final controller = AppController(app.deps());
  await tester.pumpWidget(MaterialApp(theme: OtTheme.light, home: AppRoot(controller: controller)));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> connect(WidgetTester tester, String address) async {
  await tester.enterText(find.byKey(const Key('setup-address')), address);
  await tester.tap(find.byKey(const Key('setup-connect')));
  await tester.pumpAndSettle();
}

String errorText(WidgetTester tester, String key) {
  final notice = tester.widget<Notice>(find.byKey(Key(key)));
  return notice.text;
}

Future<void> signIn(WidgetTester tester, {String password = 'pw'}) async {
  await tester.enterText(find.byKey(const Key('sign-in-email')), 'me@a.test');
  await tester.enterText(find.byKey(const Key('sign-in-password')), password);
  await tester.tap(find.byKey(const Key('sign-in-submit')));
  await tester.pumpAndSettle();
}

bool onToday(WidgetTester tester) =>
    find.byType(AppShell).evaluate().isNotEmpty &&
    find.descendant(of: find.byType(AppBar), matching: find.text('Today')).evaluate().isNotEmpty;

void main() {
  group('start-up', () {
    testWidgets('no saved session → setup', (tester) async {
      final app = FakeApp();
      final c = await pumpRoot(tester, app);
      expect(c.stage, isA<StageSetup>());
      expect(find.byType(SetupScreen), findsOneWidget);
    });

    testWidgets('a saved session is restored straight into the app', (tester) async {
      final app = FakeApp();
      await tester.runAsync(() => app.accounts().signInWithPassword(
          serverUrl: 'https://a.test', email: 'me@a.test', password: 'pw'));
      final c = await pumpRoot(tester, app);
      expect(c.stage, isA<StageReady>());
      expect(onToday(tester), isTrue);
    });
  });

  group('setup', () {
    testWidgets('bad address → clear error, no request', (tester) async {
      final app = FakeApp();
      await pumpRoot(tester, app);
      await connect(tester, 'not an address');
      expect(errorText(tester, 'setup-error'), contains('not a server address'));
      expect(app.healthChecked, isEmpty);
    });

    testWidgets('public http is refused with the https address offered', (tester) async {
      final app = FakeApp();
      await pumpRoot(tester, app);
      await connect(tester, 'http://todo.example.com');
      expect(errorText(tester, 'setup-error'), contains('Plain http'));
      await tester.tap(find.text('Use https://todo.example.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('setup-connect')));
      await tester.pumpAndSettle();
      expect(app.healthChecked, ['https://todo.example.com']);
      expect(find.byType(SignInScreen), findsOneWidget);
    });

    testWidgets('local http needs the warning acknowledged', (tester) async {
      final app = FakeApp();
      final c = await pumpRoot(tester, app);
      await connect(tester, 'http://192.168.1.4:8080');
      expect(find.byKey(const Key('setup-insecure-warning')), findsOneWidget);
      expect(app.healthChecked, isEmpty);
      expect(find.text('Connect anyway'), findsOneWidget);
      await tester.tap(find.byKey(const Key('setup-connect')));
      await tester.pumpAndSettle();
      expect(app.healthChecked, ['http://192.168.1.4:8080']);
      final stage = c.stage as StageSignIn;
      expect(stage.insecure, isTrue);
      expect(find.textContaining('Not encrypted'), findsOneWidget);
    });

    for (final (problem, words) in [
      (HealthProblem.noNetwork, 'No answer from https://a.test'),
      (HealthProblem.notOpenTodo, 'not an OpenTodo server'),
      (HealthProblem.untrusted, 'not trusted'),
    ]) {
      testWidgets('failed health check names ${problem.name}', (tester) async {
        final app = FakeApp()..health = (_) async => throw HealthCheckFailed(problem);
        await pumpRoot(tester, app);
        await connect(tester, 'a.test');
        expect(errorText(tester, 'setup-error'), contains(words));
        expect(find.byType(SetupScreen), findsOneWidget);
      });
    }

    testWidgets('a healthy server leads to sign-in; change server goes back', (tester) async {
      final app = FakeApp();
      final c = await pumpRoot(tester, app);
      await connect(tester, '  A.test/ ');
      expect((c.stage as StageSignIn).origin, 'https://a.test');
      expect(find.text('https://a.test'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sign-in-change-server')));
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.text('https://a.test'), findsOneWidget); // pre-filled
    });
  });

  group('sign-in', () {
    Future<AppController> toSignIn(WidgetTester tester, FakeApp app) async {
      final c = await pumpRoot(tester, app);
      await connect(tester, 'a.test');
      return c;
    }

    testWidgets('successful sign-in leads to Today', (tester) async {
      final app = FakeApp();
      final c = await toSignIn(tester, app);
      await signIn(tester);
      expect(c.stage, isA<StageReady>());
      expect(onToday(tester), isTrue);
      expect(app.secure.values[SecureKeys.token], 'ot_secret');
    });

    testWidgets('wrong password is named and stays on sign-in', (tester) async {
      final app = FakeApp();
      await toSignIn(tester, app);
      await signIn(tester, password: 'nope');
      expect(errorText(tester, 'sign-in-error'), 'Wrong email or password.');
      expect(find.byType(SignInScreen), findsOneWidget);
    });

    testWidgets('rate limit and account lock are named with the wait', (tester) async {
      final app = FakeApp();
      app.server.loginOverride = jsonRes({
        'error': {'code': 'account_locked', 'message': 'locked'}
      }, status: 429, headers: {'retry-after': '900'});
      await toSignIn(tester, app);
      await signIn(tester);
      expect(errorText(tester, 'sign-in-error'),
          'Too many failed attempts on this account. Try again in 15 min.');
    });

    testWidgets('MFA branch: wrong code, then the right one', (tester) async {
      final app = FakeApp()..server.mfa = true;
      final c = await toSignIn(tester, app);
      await signIn(tester);
      expect(find.text('Two-factor authentication'), findsOneWidget);
      expect(find.byKey(const Key('sign-in-code')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sign-in-code')), '000000');
      await tester.tap(find.byKey(const Key('sign-in-submit')));
      await tester.pumpAndSettle();
      expect(errorText(tester, 'sign-in-error'), contains('code is not right'));

      await tester.enterText(find.byKey(const Key('sign-in-code')), '123456');
      await tester.tap(find.byKey(const Key('sign-in-submit')));
      await tester.pumpAndSettle();
      expect(c.stage, isA<StageReady>());
      expect(onToday(tester), isTrue);
      expect(app.server.calls, contains('POST /api/v1/auth/mfa'));
    });

    testWidgets('sign-out returns to setup with the server pre-filled', (tester) async {
      final app = FakeApp();
      final c = await toSignIn(tester, app);
      await signIn(tester);
      await c.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.text('https://a.test'), findsOneWidget);
      expect(app.secure.values, isEmpty);
    });
  });

  group('messages', () {
    test('sign-in errors', () {
      expect(signInErrorMessage(RateLimitedError(429, 'rate_limited', ''), mfa: false),
          'Too many attempts from this network. Try again in a few minutes.');
      expect(
          signInErrorMessage(
              UnauthorizedError(401, 'mfa_challenge_invalid', ''), mfa: false),
          contains('expired'));
      expect(signInErrorMessage(ApiError(403, 'mfa_enrolment_required', ''), mfa: false),
          contains('requires two-factor'));
      expect(signInErrorMessage(NetworkError('x'), mfa: false), contains('No answer'));
    });
  });

  group('ServerAddress', () {
    String? origin(String s) => switch (ServerAddress.parse(s)) {
          ValidAddress(:final origin) => origin,
          _ => null,
        };

    test('https by default, normalised origin', () {
      expect(origin('todo.example.com'), 'https://todo.example.com');
      expect(origin('HTTPS://Todo.Example.com:443/'), 'https://todo.example.com');
      expect(origin('todo.example.com:8443'), 'https://todo.example.com:8443');
      expect(origin('http://localhost:8080'), 'http://localhost:8080');
      expect(origin('http://[::1]:80'), 'http://[::1]');
    });

    test('invalid addresses', () {
      for (final s in [
        '',
        'a b',
        'ftp://x.test',
        'https://x.test/app',
        'https://u:p@x.test',
        'https://x.test?q=1',
        'https://x.test:70000',
        'https://bücher.example',
      ]) {
        expect(ServerAddress.parse(s), isA<InvalidAddress>(), reason: s);
      }
    });

    test('plain http only for local addresses', () {
      for (final h in [
        'localhost',
        'box.local',
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.4',
        '169.254.1.1',
        '[fd00::1]',
        '[fe80::1]',
      ]) {
        final a = ServerAddress.parse('http://$h');
        expect(a, isA<ValidAddress>(), reason: h);
        expect((a as ValidAddress).insecure, isTrue);
      }
      for (final h in ['example.com', '172.32.0.1', '8.8.8.8', '[2001:db8::1]']) {
        expect(ServerAddress.parse('http://$h'), isA<NeedsHttps>(), reason: h);
      }
      expect((ServerAddress.parse('http://example.com:8080') as NeedsHttps).suggestion,
          'https://example.com:8080');
    });
  });

  group('health check', () {
    Future<HealthProblem?> check(MockClient client) async {
      try {
        await checkServerHealth('https://a.test',
            api: (o) => ApiClient(o, client: client, maxAttempts: 1));
        return null;
      } on HealthCheckFailed catch (e) {
        return e.problem;
      }
    }

    test('ok, with the /healthz fallback', () async {
      expect(
          await check(MockClient((r) async => r.url.path == '/healthz'
              ? jsonRes({'status': 'ok', 'version': '1.0.0'})
              : http.Response('nope', 404))),
          isNull);
    });

    test('named failures', () async {
      expect(await check(MockClient((_) async => http.Response('<html>', 200))),
          HealthProblem.notOpenTodo);
      expect(await check(MockClient((_) async => jsonRes({'status': 'down'}))),
          HealthProblem.notOpenTodo);
      expect(await check(MockClient((_) async => throw http.ClientException('refused'))),
          HealthProblem.noNetwork);
      expect(await check(MockClient((_) async => throw const HandshakeException('bad cert'))),
          HealthProblem.untrusted);
    });
  });
}
