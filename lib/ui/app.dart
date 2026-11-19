// The app shell: the top-level stage (session restore → setup → sign-in →
// app), bottom navigation between Today / Inbox / Projects / Search, the
// sync status pill, the offline banner and pull-to-sync.
//
// Screens plug in through [AppShell.tabBuilder] and read the signed-in
// session (store, clock, sync) with `SessionScope.of(context)`.

import 'package:material_ui/material_ui.dart';

import '../data/sync_engine.dart';
import 'bootstrap.dart';
import 'screens/setup.dart';
import 'screens/sign_in.dart';
import 'sync_controller.dart';
import 'theme.dart';
import 'tokens.dart';

/// Shows the screen of the [AppController]'s stage; starts the session
/// restore when first built.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.controller, this.tabBuilder});

  final AppController controller;

  /// Passed on to [AppShell.tabBuilder].
  final TabBuilder? tabBuilder;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.stage is StageLoading) widget.controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => switch (c.stage) {
        StageLoading() => const _Loading(),
        StageSetup(:final address, :final notice) => SetupScreen(
            key: const ValueKey('setup'),
            healthCheck: c.deps.healthCheck,
            initialAddress: address,
            notice: notice,
            onConnected: (origin, insecure, health) =>
                c.serverChosen(origin, insecure: insecure, health: health),
          ),
        StageSignIn(:final origin, :final insecure) => SignInScreen(
            key: ValueKey('sign-in:$origin'),
            accounts: c.accounts,
            origin: origin,
            insecure: insecure,
            onSignedIn: c.signedIn,
            onChangeServer: c.changeServer,
          ),
        StageReady(:final session) => AppShell(
            key: ValueKey('shell:${session.account.userId}'),
            session: session,
            onSignOut: c.signOut,
            tabBuilder: widget.tabBuilder,
          ),
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

// ---- session access ----

/// The signed-in session for everything under the shell.
class SessionScope extends InheritedWidget {
  const SessionScope({super.key, required this.session, required super.child});

  final AppSession session;

  static AppSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'no SessionScope above this widget');
    return scope!.session;
  }

  @override
  bool updateShouldNotify(SessionScope oldWidget) => session != oldWidget.session;
}

// ---- shell ----

enum AppTab {
  today('Today', Icons.today_outlined, Icons.today),
  inbox('Inbox', Icons.inbox_outlined, Icons.inbox),
  projects('Projects', Icons.folder_outlined, Icons.folder),
  search('Search', Icons.search_outlined, Icons.search);

  const AppTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Builds the body of a tab. Wrap scrollable lists in [SyncRefresh] for
/// pull-to-sync.
typedef TabBuilder = Widget Function(BuildContext context, AppTab tab);

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.session,
    this.onSignOut,
    this.tabBuilder,
    this.initialTab = AppTab.today,
  });

  final AppSession session;
  final Future<void> Function()? onSignOut;

  /// The tab bodies; placeholders when null (lists arrive in M3.4).
  final TabBuilder? tabBuilder;
  final AppTab initialTab;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late AppTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final build = widget.tabBuilder ?? placeholderTab;
    return SessionScope(
      session: widget.session,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_tab.label),
          actions: [
            SyncStatusPill(sync: widget.session.sync),
            _AccountMenu(
              email: widget.session.account.email,
              onSignOut: widget.onSignOut,
            ),
          ],
        ),
        body: Column(
          children: [
            OfflineBanner(sync: widget.session.sync),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  for (final t in AppTab.values)
                    KeyedSubtree(
                      key: ValueKey('tab:${t.name}'),
                      child: Builder(builder: (context) => build(context, t)),
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (i) => setState(() => _tab = AppTab.values[i]),
          destinations: [
            for (final t in AppTab.values)
              NavigationDestination(
                icon: Icon(t.icon),
                selectedIcon: Icon(t.selectedIcon),
                label: t.label,
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.email, this.onSignOut});

  final String email;
  final Future<void> Function()? onSignOut;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('account-menu'),
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        if (v == 'sign-out') onSignOut?.call();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(email, style: TextStyle(color: context.ot.muted)),
        ),
        const PopupMenuItem(value: 'sign-out', child: Text('Sign out')),
      ],
    );
  }
}

/// The body of a tab until its real screen exists.
Widget placeholderTab(BuildContext context, AppTab tab) {
  return SyncRefresh(
    child: ListView(
      key: ValueKey('placeholder:${tab.name}'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Text('${tab.label} is coming soon',
              style: OtType.body.copyWith(color: context.ot.muted)),
        ),
      ],
    ),
  );
}

/// Pull-to-sync around a scrollable [child] (which must always be
/// scrollable, e.g. [AlwaysScrollableScrollPhysics]).
class SyncRefresh extends StatelessWidget {
  const SyncRefresh({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sync = SessionScope.of(context).sync;
    return RefreshIndicator(onRefresh: sync.syncNow, child: child);
  }
}

// ---- sync status ----

/// Rebuilds with every status of [sync].
class SyncStatusBuilder extends StatelessWidget {
  const SyncStatusBuilder({super.key, required this.sync, required this.builder});

  final SyncController sync;
  final Widget Function(BuildContext context, SyncStatus status) builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: sync.statusStream,
      initialData: sync.status,
      builder: (context, snap) => builder(context, snap.data ?? sync.status),
    );
  }
}

/// What the pill says for a status, and in which tone.
enum PillTone { success, info, muted, warning, danger }

({String label, IconData icon, PillTone tone}) describeSyncStatus(SyncStatus s) =>
    switch (s.phase) {
      SyncPhase.syncing => (label: 'Syncing', icon: Icons.sync, tone: PillTone.info),
      SyncPhase.reseeding =>
        (label: 'Re-syncing', icon: Icons.sync_problem, tone: PillTone.info),
      SyncPhase.offline =>
        (label: 'Offline', icon: Icons.cloud_off_outlined, tone: PillTone.muted),
      SyncPhase.error =>
        (label: 'Sync error', icon: Icons.error_outline, tone: PillTone.danger),
      SyncPhase.idle when s.rejected > 0 => (
          label: '${s.rejected} not saved',
          icon: Icons.warning_amber_outlined,
          tone: PillTone.warning
        ),
      SyncPhase.idle when s.pending > 0 =>
        (label: '${s.pending} pending', icon: Icons.cloud_upload_outlined, tone: PillTone.muted),
      SyncPhase.idle => (label: 'Synced', icon: Icons.cloud_done_outlined, tone: PillTone.success),
    };

class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key, required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
    return SyncStatusBuilder(
      sync: sync,
      builder: (context, status) {
        final d = describeSyncStatus(status);
        final (bg, fg) = switch (d.tone) {
          PillTone.success => (c.successSoft, c.successSoftText),
          PillTone.info => (c.infoSoft, c.infoSoftText),
          PillTone.muted => (c.sunken, c.muted),
          PillTone.warning => (c.warningSoft, c.warningSoftText),
          PillTone.danger => (c.dangerSoft, c.dangerSoftText),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: Material(
              key: const Key('sync-pill'),
              color: bg,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _tap(context, status),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(d.icon, size: 14, color: fg),
                      const SizedBox(width: 4),
                      Text(d.label, style: OtType.meta.copyWith(color: fg)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _tap(BuildContext context, SyncStatus status) {
    final error = status.error;
    if (status.phase == SyncPhase.error && error != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error)));
    }
    sync.syncNow();
  }
}

/// A strip under the app bar while the server cannot be reached.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
    return SyncStatusBuilder(
      sync: sync,
      builder: (context, status) {
        if (status.phase != SyncPhase.offline) return const SizedBox.shrink();
        return Container(
          key: const Key('offline-banner'),
          width: double.infinity,
          color: c.warningSoft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Offline. Changes stay on this device and sync when the connection returns.',
            style: OtType.meta.copyWith(color: c.warningSoftText),
          ),
        );
      },
    );
  }
}
