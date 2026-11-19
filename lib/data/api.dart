// REST client for the OpenTodo server (docs/api.md): health, the password
// sign-in flow of `ot login` (login → session cookie → POST tokens → secret),
// two-factor challenge, credential introspection (`me`), the end-to-end
// encryption key record and the sync exchange.
//
// Two credentials, never mixed:
// - the session cookie (`opentodo_session`, plus `ot_trust` after a remembered
//   second factor) is sent only on the sign-in and credential routes;
// - the bearer token is sent on everything else.
// Cookie writes go without an `Origin` header and with a JSON body, which is
// what the server accepts from a non-browser client (docs/api.md, "How a
// non-browser client signs in").

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/e2ee.dart' show KeyRecord;

// ---- errors ----

/// A response with an error status, parsed from the `{error:{code,message}}`
/// envelope when the server sent one.
class ApiError implements Exception {
  final int status;
  final String code;
  final String message;

  /// The server's `Retry-After`, when it sent one.
  final Duration? retryAfter;

  ApiError(this.status, this.code, this.message, {this.retryAfter});

  @override
  String toString() => 'ApiError($status $code: $message)';
}

/// 401: the credential is missing, wrong, expired or revoked
/// (`invalid_credentials`, `unauthorized`, `mfa_code_invalid`, …).
class UnauthorizedError extends ApiError {
  UnauthorizedError(super.status, super.code, super.message,
      {super.retryAfter});
}

/// 429 (and 503 `busy`) that outlasted the retries, or whose `Retry-After`
/// was longer than this client waits on its own (e.g. `account_locked`).
class RateLimitedError extends ApiError {
  RateLimitedError(super.status, super.code, super.message,
      {super.retryAfter});
}

/// No answer: connection failure or timeout.
class NetworkError implements Exception {
  final Object cause;
  NetworkError(this.cause);

  @override
  String toString() => 'NetworkError($cause)';
}

// ---- backoff ----

/// Exponential backoff with jitter: 1 s, 2 s, 4 s … capped at 30 s; each
/// delay is drawn from [d/2, d] so clients that failed together spread out.
class Backoff {
  final Duration base;
  final Duration max;
  final math.Random _random;

  Backoff({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    math.Random? random,
  }) : _random = random ?? math.Random();

  /// The delay before retry number [attempt] (0-based).
  Duration delay(int attempt) {
    final shift = math.min(attempt, 20);
    final full = math.min(base.inMilliseconds * (1 << shift), max.inMilliseconds);
    final half = full ~/ 2;
    return Duration(milliseconds: half + _random.nextInt(full - half + 1));
  }
}

// ---- results ----

class HealthInfo {
  final String status;
  final String? version;
  final bool appSignIn;

  HealthInfo({required this.status, this.version, this.appSignIn = false});

  factory HealthInfo.fromJson(Map<String, dynamic> j) => HealthInfo(
        status: j['status'] as String,
        version: j['version'] as String?,
        appSignIn: j['app_sign_in'] == true,
      );
}

/// The answer of `auth/login`: either signed in (`user`, cookie set) or a
/// second factor is needed (`mfaRequired`, `challenge`, no cookie).
class LoginResult {
  final Map<String, dynamic>? user;
  final bool mfaRequired;
  final String? challenge;
  final int? expiresAt;

  LoginResult({this.user, this.mfaRequired = false, this.challenge, this.expiresAt});

  factory LoginResult.fromJson(Map<String, dynamic> j) => LoginResult(
        user: j['user'] as Map<String, dynamic>?,
        mfaRequired: j['mfaRequired'] == true,
        challenge: j['challenge'] as String?,
        expiresAt: (j['expiresAt'] as num?)?.toInt(),
      );
}

/// `POST /api/v1/tokens` → `{token, secret}`; the secret is shown once.
class CreatedToken {
  final Map<String, dynamic> token;
  final String secret;

  CreatedToken(this.token, this.secret);

  String? get id => token['id'] as String?;
}

/// `GET /api/v1/me`.
class MeInfo {
  final Map<String, dynamic> raw;

  MeInfo(this.raw);

  Map<String, dynamic> get user => (raw['user'] as Map<String, dynamic>?) ?? const {};
  String get userId => user['id'] as String? ?? '';
  String get email => user['email'] as String? ?? '';
  bool get encryptionEnabled =>
      (raw['encryption'] as Map<String, dynamic>?)?['enabled'] == true;
  int get keyVersion =>
      ((raw['encryption'] as Map<String, dynamic>?)?['keyVersion'] as num?)?.toInt() ?? 0;

  /// `session` or `token`.
  String? get authMethod => (raw['auth'] as Map<String, dynamic>?)?['method'] as String?;

  /// `full`, `read`, `agent`, `admin` or `app`.
  String? get authScope => (raw['auth'] as Map<String, dynamic>?)?['scope'] as String?;
}

// ---- client ----

enum _Cred { none, bearer, session, auto }

class ApiClient {
  /// Server origin without a trailing slash, e.g. `https://todo.example.com`.
  final String baseUrl;
  final http.Client _http;

  /// The bearer secret (`ot_…`); null until signed in.
  String? token;

  final Duration timeout;

  /// Total tries per request for retryable failures (429, 502–504, network).
  final int maxAttempts;
  final Backoff backoff;
  final Future<void> Function(Duration) _sleep;

  /// The session cookie jar: name → value.
  final Map<String, String> _cookies = {};

  ApiClient(
    String baseUrl, {
    http.Client? client,
    this.token,
    this.timeout = const Duration(seconds: 30),
    this.maxAttempts = 4,
    Backoff? backoff,
    Future<void> Function(Duration)? sleep,
  })  : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client(),
        backoff = backoff ?? Backoff(),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  // ---- session cookie ----

  bool get hasSession => _cookies.isNotEmpty;

  /// The jar as a `Cookie` header value, for secure storage.
  String? get sessionCookie => _cookies.isEmpty
      ? null
      : _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// Restores a jar saved with [sessionCookie].
  set sessionCookie(String? header) {
    _cookies.clear();
    if (header == null) return;
    for (final part in header.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      _cookies[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
  }

  void clearSession() => _cookies.clear();

  // ---- health and sign-in ----

  /// `GET /api/v1/health`, then `/healthz` when a proxy answers the API path
  /// itself (non-JSON or 404), like the mobile apps.
  Future<HealthInfo> health() async {
    try {
      final j = await _json('GET', '/api/v1/health', cred: _Cred.none);
      if (j is Map<String, dynamic> && j['status'] is String) {
        return HealthInfo.fromJson(j);
      }
    } on ApiError catch (e) {
      if (e.status != 404) rethrow;
    } on FormatException {
      // Not our server's JSON: try the root path.
    }
    final j = await _json('GET', '/healthz', cred: _Cred.none);
    return HealthInfo.fromJson(j as Map<String, dynamic>);
  }

  /// `POST /api/v1/auth/login`; on success the session cookie is in the jar.
  Future<LoginResult> login(String email, String password) async {
    final j = await _json('POST', '/api/v1/auth/login',
        body: {'email': email, 'password': password}, cred: _Cred.session);
    return LoginResult.fromJson(j as Map<String, dynamic>);
  }

  /// `POST /api/v1/auth/mfa` with an authenticator [code] or a
  /// [recoveryCode]; on success the session cookie is in the jar.
  Future<Map<String, dynamic>?> mfa(String challenge,
      {String? code, String? recoveryCode, bool remember = false}) async {
    final body = <String, dynamic>{'challenge': challenge};
    if (code != null) body['code'] = code;
    if (recoveryCode != null) body['recoveryCode'] = recoveryCode;
    if (remember) body['remember'] = true;
    final j = await _json('POST', '/api/v1/auth/mfa', body: body, cred: _Cred.session);
    return (j as Map<String, dynamic>)['user'] as Map<String, dynamic>?;
  }

  /// `POST /api/v1/tokens` from the session (a credential route); the caller
  /// keeps only `secret` and sets it as [token].
  Future<CreatedToken> createToken(String name, {String? scope}) async {
    final body = <String, dynamic>{'name': name};
    if (scope != null) body['scope'] = scope;
    final j = await _json('POST', '/api/v1/tokens', body: body, cred: _Cred.session)
        as Map<String, dynamic>;
    return CreatedToken(
        (j['token'] as Map<String, dynamic>?) ?? const {}, j['secret'] as String);
  }

  /// `DELETE /api/v1/tokens/{id}` (allowed to any token, including itself).
  Future<void> deleteToken(String id) async {
    await _json('DELETE', '/api/v1/tokens/${Uri.encodeComponent(id)}', cred: _Cred.auto);
  }

  /// `POST /api/v1/auth/logout` with the cookie, then forgets the jar
  /// whatever the answer.
  Future<void> logout() async {
    if (!hasSession) return;
    try {
      // A JSON body, so the cookie write passes the Origin check.
      await _json('POST', '/api/v1/auth/logout', body: const {}, cred: _Cred.session);
    } finally {
      _cookies.clear();
    }
  }

  // ---- account ----

  /// `GET /api/v1/me` with the bearer token (the session when there is none).
  Future<MeInfo> me() async =>
      MeInfo(await _json('GET', '/api/v1/me', cred: _Cred.auto) as Map<String, dynamic>);

  /// `GET /api/v1/encryption/keys`; null when the account has no key record
  /// (404 `encryption_disabled`).
  Future<KeyRecord?> getKeyRecord() async {
    try {
      final j = await _json('GET', '/api/v1/encryption/keys', cred: _Cred.auto)
          as Map<String, dynamic>;
      return KeyRecord.fromJson(j['keys'] as Map<String, dynamic>);
    } on ApiError catch (e) {
      if (e.status == 404 && e.code == 'encryption_disabled') return null;
      rethrow;
    }
  }

  /// `PUT /api/v1/encryption/keys`: a credential route, so it goes with the
  /// session cookie (a `full`/`app` token gets 403 `insufficient_scope`);
  /// without a session it falls back to the bearer token (works for `admin`).
  /// 409 `encryption_conflict` means another device was first.
  Future<KeyRecord> putKeyRecord(KeyRecord record) async {
    final j = await _json('PUT', '/api/v1/encryption/keys',
        body: record.toJson(), cred: hasSession ? _Cred.session : _Cred.bearer)
        as Map<String, dynamic>;
    return KeyRecord.fromJson(j['keys'] as Map<String, dynamic>);
  }

  // ---- sync ----

  /// `POST /api/v1/sync` with the bearer token (docs/sync.md, Exchange): the
  /// body is `{device, cursor, ops, features, …}`, the answer the raw page.
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> body) async =>
      await _json('POST', '/api/v1/sync', body: body, cred: _Cred.bearer)
          as Map<String, dynamic>;

  /// A bearer request to any other `/api/v1` route; returns the decoded JSON
  /// (null for an empty body).
  Future<Object?> send(String method, String path,
          {Object? body, Map<String, String>? query}) =>
      _json(method, path, body: body, query: query, cred: _Cred.bearer);

  void close() => _http.close();

  // ---- transport ----

  Future<Object?> _json(String method, String path,
      {Object? body, Map<String, String>? query, required _Cred cred}) async {
    final res = await _send(method, path, body: body, query: query, cred: cred);
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }

  Future<http.Response> _send(String method, String path,
      {Object? body, Map<String, String>? query, required _Cred cred}) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final encoded = body == null ? null : jsonEncode(body);
    for (var attempt = 0;; attempt++) {
      final last = attempt + 1 >= maxAttempts;
      final req = http.Request(method, uri);
      req.headers['Accept'] = 'application/json';
      if (encoded != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = encoded;
      }
      _authorize(req, cred);

      http.Response res;
      try {
        res = await http.Response.fromStream(await _http.send(req).timeout(timeout))
            .timeout(timeout);
      } on TimeoutException catch (e) {
        if (last) throw NetworkError(e);
        await _sleep(backoff.delay(attempt));
        continue;
      } on http.ClientException catch (e) {
        if (last) throw NetworkError(e);
        await _sleep(backoff.delay(attempt));
        continue;
      }

      if (cred == _Cred.session || (cred == _Cred.auto && token == null)) {
        _storeCookies(res);
      }
      if (res.statusCode < 400) return res;

      final err = _error(res);
      final retryable = res.statusCode == 429 || (res.statusCode >= 502 && res.statusCode <= 504);
      if (!retryable) throw err;
      var wait = backoff.delay(attempt);
      final ra = err.retryAfter;
      if (ra != null) {
        // A long lock (account_locked, 15 min) is the caller's to show, not ours to sit out.
        if (ra > backoff.max) throw _limited(err);
        if (ra > wait) wait = ra;
      }
      if (last) throw res.statusCode == 429 || err.code == 'busy' ? _limited(err) : err;
      await _sleep(wait);
    }
  }

  void _authorize(http.Request req, _Cred cred) {
    var c = cred;
    if (c == _Cred.auto) {
      c = token != null ? _Cred.bearer : (hasSession ? _Cred.session : _Cred.none);
    }
    switch (c) {
      case _Cred.bearer:
        final t = token;
        if (t == null) throw StateError('no bearer token: sign in first');
        req.headers['Authorization'] = 'Bearer $t';
      case _Cred.session:
        final cookie = sessionCookie;
        if (cookie != null) req.headers['Cookie'] = cookie;
      case _Cred.none:
      case _Cred.auto:
        break;
    }
  }

  void _storeCookies(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final c in splitSetCookie(raw)) {
      final attrs = c.split(';');
      final nv = attrs.first;
      final i = nv.indexOf('=');
      if (i <= 0) continue;
      final name = nv.substring(0, i).trim();
      final value = nv.substring(i + 1).trim();
      final expired = value.isEmpty ||
          attrs.skip(1).any((a) {
            final t = a.trim().toLowerCase();
            return t.startsWith('max-age=') && (int.tryParse(t.substring(8)) ?? 1) <= 0;
          });
      if (expired) {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }

  static ApiError _error(http.Response res) {
    var code = 'http_${res.statusCode}';
    var message = res.reasonPhrase ?? '';
    try {
      final j = jsonDecode(res.body);
      if (j is Map<String, dynamic> && j['error'] is Map<String, dynamic>) {
        final e = j['error'] as Map<String, dynamic>;
        code = e['code'] as String? ?? code;
        message = e['message'] as String? ?? message;
      }
    } on FormatException {
      // Not an envelope (a proxy page): keep the status.
    }
    final raSecs = int.tryParse(res.headers['retry-after'] ?? '');
    final ra = raSecs == null ? null : Duration(seconds: raSecs);
    if (res.statusCode == 401) return UnauthorizedError(res.statusCode, code, message, retryAfter: ra);
    return ApiError(res.statusCode, code, message, retryAfter: ra);
  }

  static RateLimitedError _limited(ApiError e) =>
      RateLimitedError(e.status, e.code, e.message, retryAfter: e.retryAfter);
}

/// Splits a `Set-Cookie` value that `package:http` joined with commas,
/// without breaking the comma inside an `Expires` date.
List<String> splitSetCookie(String header) =>
    header.split(RegExp(r',(?=\s*[^\s=;,]+=)'));
