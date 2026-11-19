// The signed-in account of this installation and its secrets.
//
// Non-secret facts (server, user, encryption state, device id) live in
// [AccountState]; the bearer token, the session cookie and the content key
// (DEK) live only in secure storage. Sign-out mirrors `stopSync` +
// `clearLocalData` in web/src/lib/sync.ts and db.ts: a new epoch, the sync
// engine stopped, the local database cleared, every secret forgotten.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/e2ee.dart' show b64url, fromB64url;
import '../core/ids.dart' show uuid;
import 'api.dart';
import 'secure_store.dart';

class AccountState {
  final String serverUrl;
  final String userId;
  final String email;
  final bool encrypted;
  final int keyVersion;

  /// This installation's sync device id (`flutter:<uuid>`), docs/sync.md
  /// "Device ids".
  final String deviceId;

  const AccountState({
    required this.serverUrl,
    required this.userId,
    required this.email,
    required this.encrypted,
    required this.keyVersion,
    required this.deviceId,
  });

  AccountState copyWith({String? email, bool? encrypted, int? keyVersion}) =>
      AccountState(
        serverUrl: serverUrl,
        userId: userId,
        email: email ?? this.email,
        encrypted: encrypted ?? this.encrypted,
        keyVersion: keyVersion ?? this.keyVersion,
        deviceId: deviceId,
      );

  factory AccountState.fromJson(Map<String, dynamic> j) => AccountState(
        serverUrl: j['serverUrl'] as String,
        userId: j['userId'] as String,
        email: j['email'] as String? ?? '',
        encrypted: j['encrypted'] == true,
        keyVersion: (j['keyVersion'] as num?)?.toInt() ?? 0,
        deviceId: j['deviceId'] as String,
      );

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'userId': userId,
        'email': email,
        'encrypted': encrypted,
        'keyVersion': keyVersion,
        'deviceId': deviceId,
      };
}

/// What `signInWithPassword` returns: signed in, or a second factor is needed
/// (finish with [AccountManager.completeMfa]).
sealed class SignInStep {}

class SignedIn extends SignInStep {
  final AccountState account;
  SignedIn(this.account);
}

class MfaRequired extends SignInStep {
  final String challenge;
  MfaRequired(this.challenge);
}

/// Secure-storage keys; all of them are removed at sign-out.
abstract final class SecureKeys {
  static const account = 'opentodo.account';
  static const token = 'opentodo.token';
  static const tokenId = 'opentodo.token_id';
  static const session = 'opentodo.session';
  static const dek = 'opentodo.dek';
  static const deviceId = 'opentodo.device';

  static const all = [account, token, tokenId, session, dek, deviceId];
}

class AccountManager {
  final SecureStore store;
  final ApiClient Function(String baseUrl) _apiFactory;

  /// Stops the sync engine (M1.5); awaited before anything is cleared.
  final Future<void> Function() _stopSync;

  /// Clears the local database (M1.2 store) of the signed-out account.
  final Future<void> Function() _clearLocalData;
  final String Function() _newDeviceId;

  AccountState? _state;
  ApiClient? _api;
  Uint8List? _dek;
  int _epoch = 0;

  // The half-finished sign-in waiting for a second factor.
  ApiClient? _pending;
  String? _pendingServer;
  String? _pendingChallenge;
  String? _pendingTokenName;

  AccountManager({
    required this.store,
    ApiClient Function(String baseUrl)? apiFactory,
    Future<void> Function()? stopSync,
    Future<void> Function()? clearLocalData,
    String Function()? newDeviceId,
  })  : _apiFactory = apiFactory ?? ApiClient.new,
        _stopSync = stopSync ?? _noop,
        _clearLocalData = clearLocalData ?? _noop,
        _newDeviceId = newDeviceId ?? (() => 'flutter:${uuid()}');

  static Future<void> _noop() async {}

  AccountState? get state => _state;
  bool get signedIn => _state != null;

  /// The client of the signed-in account (bearer token set).
  ApiClient? get api => _api;

  /// Bumped by every sign-out: work started under an older epoch (an
  /// exchange in flight) must not write anything afterwards.
  int get epoch => _epoch;

  /// Loads the saved session at start-up; null when signed out.
  Future<AccountState?> restore() async {
    final raw = await store.read(SecureKeys.account);
    final token = await store.read(SecureKeys.token);
    if (raw == null || token == null) return null;
    final state = AccountState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final api = _apiFactory(state.serverUrl)..token = token;
    api.sessionCookie = await store.read(SecureKeys.session);
    final dek = await store.read(SecureKeys.dek);
    _dek = dek == null ? null : fromB64url(dek);
    _api = api;
    _state = state;
    return state;
  }

  /// The `ot login` flow: login → (second factor) → POST tokens → me. The
  /// session cookie is kept (secure storage) for the credential routes such
  /// as the encryption key record.
  Future<SignInStep> signInWithPassword({
    required String serverUrl,
    required String email,
    required String password,
    String tokenName = 'flutter',
  }) async {
    final api = _apiFactory(serverUrl);
    final res = await api.login(email, password);
    if (res.mfaRequired) {
      _pending = api;
      _pendingServer = serverUrl;
      _pendingChallenge = res.challenge;
      _pendingTokenName = tokenName;
      return MfaRequired(res.challenge ?? '');
    }
    return SignedIn(await _finishPasswordSignIn(api, serverUrl, tokenName));
  }

  /// Answers the challenge of the last [signInWithPassword].
  Future<AccountState> completeMfa({String? code, String? recoveryCode}) async {
    final api = _pending;
    final challenge = _pendingChallenge;
    if (api == null || challenge == null) {
      throw StateError('no sign-in is waiting for a second factor');
    }
    await api.mfa(challenge, code: code, recoveryCode: recoveryCode);
    final server = _pendingServer!;
    final name = _pendingTokenName!;
    _pending = null;
    _pendingChallenge = null;
    return _finishPasswordSignIn(api, server, name);
  }

  /// Signs in with an existing token (Settings → API tokens).
  Future<AccountState> signInWithToken(String serverUrl, String token) async {
    final api = _apiFactory(serverUrl)..token = token;
    return _activate(api, serverUrl, await api.me(), tokenId: null);
  }

  Future<AccountState> _finishPasswordSignIn(
      ApiClient api, String serverUrl, String tokenName) async {
    final created = await api.createToken(tokenName);
    api.token = created.secret;
    return _activate(api, serverUrl, await api.me(), tokenId: created.id);
  }

  Future<AccountState> _activate(ApiClient api, String serverUrl, MeInfo me,
      {required String? tokenId}) async {
    final old = _state;
    // Another server or another person: the local copy belongs to them.
    if (old != null &&
        (old.serverUrl != api.baseUrl || old.userId != me.userId)) {
      await _wipeLocal();
    }
    var deviceId = await store.read(SecureKeys.deviceId);
    if (deviceId == null) {
      deviceId = _newDeviceId();
      await store.write(SecureKeys.deviceId, deviceId);
    }
    final state = AccountState(
      serverUrl: api.baseUrl,
      userId: me.userId,
      email: me.email,
      encrypted: me.encryptionEnabled,
      keyVersion: me.keyVersion,
      deviceId: deviceId,
    );
    await store.write(SecureKeys.token, api.token!);
    if (tokenId != null) await store.write(SecureKeys.tokenId, tokenId);
    final cookie = api.sessionCookie;
    if (cookie != null) await store.write(SecureKeys.session, cookie);
    await store.write(SecureKeys.account, jsonEncode(state.toJson()));
    _api = api;
    _state = state;
    return state;
  }

  /// Re-reads `me` (encryption state may change on another device).
  Future<AccountState> refresh() async {
    final api = _api;
    final old = _state;
    if (api == null || old == null) throw StateError('signed out');
    final me = await api.me();
    final next = old.copyWith(
        email: me.email, encrypted: me.encryptionEnabled, keyVersion: me.keyVersion);
    if (!next.encrypted) await clearDek();
    await store.write(SecureKeys.account, jsonEncode(next.toJson()));
    _state = next;
    return next;
  }

  /// Persists the session cookie after it changed (e.g. a re-login for a
  /// credential route); null forgets it.
  Future<void> saveSession() async {
    final cookie = _api?.sessionCookie;
    if (cookie == null) {
      await store.delete(SecureKeys.session);
    } else {
      await store.write(SecureKeys.session, cookie);
    }
  }

  // ---- content key ----

  Uint8List? get dek => _dek;

  Future<void> saveDek(Uint8List key) async {
    _dek = Uint8List.fromList(key);
    await store.write(SecureKeys.dek, b64url(key));
  }

  Future<void> clearDek() async {
    _dek = null;
    await store.delete(SecureKeys.dek);
  }

  // ---- sign-out ----

  /// Stops sync, revokes the token and ends the session on the server (best
  /// effort, bounded by [remoteTimeout]), clears the local database and every
  /// secret. The device id goes too: the next sign-in copies the account
  /// from cursor 0, and a pull skips the asking device's own ops, so a reused
  /// id would hide this installation's earlier writes (web parity:
  /// clearLocalData gives a fresh device id).
  Future<void> signOut({
    bool revoke = true,
    Duration remoteTimeout = const Duration(seconds: 5),
  }) async {
    final api = _api;
    final tokenId = await store.read(SecureKeys.tokenId);
    _epoch++;
    await _stopSync();
    if (revoke && api != null) {
      await _bestEffort(() async {
        if (tokenId != null && api.token != null) await api.deleteToken(tokenId);
      }, remoteTimeout);
      await _bestEffort(api.logout, remoteTimeout);
    }
    await _clearAll();
  }

  Future<void> _wipeLocal() async {
    _epoch++;
    await _stopSync();
    await _clearAll();
  }

  Future<void> _clearAll() async {
    await _clearLocalData();
    for (final k in SecureKeys.all) {
      await store.delete(k);
    }
    _api?.clearSession();
    _api = null;
    _state = null;
    _dek = null;
    _pending = null;
    _pendingChallenge = null;
  }

  static Future<void> _bestEffort(Future<void> Function() f, Duration t) async {
    try {
      await f().timeout(t);
    } catch (_) {
      // Offline or already revoked: the local wipe goes ahead regardless.
    }
  }
}
