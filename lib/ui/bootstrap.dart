// The composition root: which secure store, database and sync engine the app
// runs on, and the app's top-level stage (loading → setup → sign-in → app).
// Everything is created through [AppDeps], so widget tests swap in fakes.

import 'package:material_ui/material_ui.dart' show ChangeNotifier;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../core/hlc.dart';
import '../data/account.dart';
import '../data/api.dart';
import '../data/secure_store.dart';
import '../data/store.dart';
import '../data/store_sqflite.dart';
import '../data/sync_engine.dart';
import 'server_address.dart';
import 'sync_controller.dart';

/// Everything the signed-in app runs on. Screens reach it through
/// `SessionScope.of(context)` (lib/ui/app.dart).
class AppSession {
  final AccountState account;

  /// The local database of the account.
  final SyncStore store;

  /// The device clock shared with the sync engine (local edits stamp with it).
  final Hlc hlc;
  final SyncController sync;
  final Future<void> Function() _close;

  AppSession({
    required this.account,
    required this.store,
    required this.hlc,
    required this.sync,
    Future<void> Function()? close,
  }) : _close = close ?? _noop;

  static Future<void> _noop() async {}

  /// Stops the engine; called before sign-out.
  Future<void> close() => _close();
}

/// Opens the session of a signed-in account (store, engine).
typedef SessionOpener = Future<AppSession> Function(
    AccountManager accounts, AccountState account);

class AppDeps {
  final AccountManager accounts;
  final SessionOpener openSession;
  final HealthCheck healthCheck;

  AppDeps({
    required this.accounts,
    required this.openSession,
    HealthCheck? healthCheck,
  }) : healthCheck = healthCheck ?? checkServerHealth;

  /// The real app: platform secure storage, one SQLite database
  /// (`opentodo.db`, cleared at sign-out) and the sync engine.
  factory AppDeps.production() {
    SyncStore? store;
    Future<SyncStore> openStore() async => store ??= await SqfliteStore.open(
        sqflite.databaseFactory, p.join(await sqflite.getDatabasesPath(), 'opentodo.db'));
    final accounts = AccountManager(
      store: PlatformSecureStore(),
      clearLocalData: () async => (await openStore()).clear(),
    );
    return AppDeps(
      accounts: accounts,
      openSession: (accounts, account) async =>
          openEngineSession(accounts.api!, account, await openStore()),
    );
  }
}

/// Starts a [SyncEngine] for [account] on [store].
///
/// An end-to-end encrypted account does not sync yet: without the content key
/// (unlock arrives with M4) the engine would push plaintext and could not read
/// what it pulls.
Future<AppSession> openEngineSession(
    ApiClient api, AccountState account, SyncStore store) async {
  final hlc = Hlc();
  if (account.encrypted) {
    return AppSession(
      account: account,
      store: store,
      hlc: hlc,
      sync: DisabledSyncController(
          'This account is end-to-end encrypted. Unlocking it on this device is not available yet.'),
    );
  }
  final engine = SyncEngine(
      store: store, exchange: api.exchange, hlc: hlc, device: account.deviceId);
  await engine.start();
  return AppSession(
    account: account,
    store: store,
    hlc: hlc,
    sync: EngineSyncController(engine),
    close: engine.dispose,
  );
}

// ---- the app's stage ----

sealed class AppStage {
  const AppStage();
}

/// Restoring the saved session.
class StageLoading extends AppStage {
  const StageLoading();
}

/// The first-run screen: no server chosen.
class StageSetup extends AppStage {
  /// Pre-filled address (the previous server after a sign-out).
  final String? address;

  /// Why the app came back here, shown once.
  final String? notice;
  const StageSetup({this.address, this.notice});
}

/// A healthy server was chosen; sign in to it.
class StageSignIn extends AppStage {
  final String origin;
  final bool insecure;
  final HealthInfo? health;
  const StageSignIn(this.origin, {this.insecure = false, this.health});
}

class StageReady extends AppStage {
  final AppSession session;
  const StageReady(this.session);
}

/// Drives the top-level stage; `AppRoot` (lib/ui/app.dart) shows the screen.
class AppController extends ChangeNotifier {
  final AppDeps deps;
  AppStage _stage = const StageLoading();

  AppController(this.deps);

  AppStage get stage => _stage;
  AccountManager get accounts => deps.accounts;

  void _go(AppStage next) {
    _stage = next;
    notifyListeners();
  }

  /// Session restore at start-up: the app when signed in, setup otherwise.
  Future<void> start() async {
    AccountState? state;
    try {
      state = await deps.accounts.restore();
    } catch (_) {
      state = null; // An unreadable saved session: start over.
    }
    if (state == null) {
      _go(const StageSetup());
    } else {
      await _open(state);
    }
  }

  void serverChosen(String origin, {bool insecure = false, HealthInfo? health}) =>
      _go(StageSignIn(origin, insecure: insecure, health: health));

  void changeServer() {
    final s = _stage;
    _go(StageSetup(address: s is StageSignIn ? s.origin : null));
  }

  Future<void> signedIn(AccountState account) => _open(account);

  /// Stops sync, then signs out (revokes the token, clears local data).
  Future<void> signOut() async {
    final s = _stage;
    final origin = deps.accounts.state?.serverUrl;
    if (s is StageReady) await s.session.close();
    await deps.accounts.signOut();
    _go(StageSetup(address: origin));
  }

  Future<void> _open(AccountState account) async {
    try {
      _go(StageReady(await deps.openSession(deps.accounts, account)));
    } catch (e) {
      _go(StageSetup(address: account.serverUrl, notice: 'Could not open the local data: $e'));
    }
  }
}
