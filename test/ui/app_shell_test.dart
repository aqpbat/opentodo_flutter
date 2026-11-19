import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opentodo_flutter/data/sync_engine.dart';
import 'package:opentodo_flutter/ui/app.dart';
import 'package:opentodo_flutter/ui/theme.dart';

import '../support/ui_fakes.dart';

Future<FakeSync> pumpShell(WidgetTester tester,
    {TabBuilder? tabBuilder, Future<void> Function()? onSignOut}) async {
  final sync = FakeSync();
  await tester.pumpWidget(MaterialApp(
    theme: OtTheme.light,
    home: AppShell(session: fakeSession(sync), tabBuilder: tabBuilder, onSignOut: onSignOut),
  ));
  return sync;
}

Finder navItem(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Finder pillText(String label) =>
    find.descendant(of: find.byKey(const Key('sync-pill')), matching: find.text(label));

void main() {
  testWidgets('starts on Today and switches tabs', (tester) async {
    await pumpShell(tester);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Today')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('placeholder:today')), findsOneWidget);

    for (final tab in ['Inbox', 'Projects', 'Search', 'Today']) {
      await tester.tap(navItem(tab));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(tab)),
          findsOneWidget);
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(AppTab.values[nav.selectedIndex].label, tab);
    }
  });

  testWidgets('tab bodies come from the tab builder and keep their state', (tester) async {
    await pumpShell(tester, tabBuilder: (context, tab) {
      // Screens reach the session through the scope.
      final session = SessionScope.of(context);
      return Text('${tab.name} of ${session.account.email}', key: ValueKey(tab));
    });
    expect(find.text('today of me@a.test'), findsOneWidget);
    await tester.tap(navItem('Search'));
    await tester.pumpAndSettle();
    expect(find.text('search of me@a.test'), findsOneWidget);
  });

  testWidgets('status pill renders every engine state', (tester) async {
    final sync = await pumpShell(tester);
    expect(pillText('Synced'), findsOneWidget);

    final cases = <SyncStatus, String>{
      const SyncStatus(phase: SyncPhase.syncing): 'Syncing',
      const SyncStatus(phase: SyncPhase.offline): 'Offline',
      const SyncStatus(phase: SyncPhase.error, error: 'boom'): 'Sync error',
      const SyncStatus(phase: SyncPhase.reseeding): 'Re-syncing',
      const SyncStatus(phase: SyncPhase.idle, pending: 3): '3 pending',
      const SyncStatus(phase: SyncPhase.idle, rejected: 2): '2 not saved',
      const SyncStatus(phase: SyncPhase.idle, lastSyncedAt: 1): 'Synced',
    };
    for (final MapEntry(key: status, value: label) in cases.entries) {
      sync.emit(status);
      await tester.pump();
      expect(pillText(label), findsOneWidget, reason: '$status');
    }
  });

  testWidgets('offline banner follows the engine', (tester) async {
    final sync = await pumpShell(tester);
    expect(find.byKey(const Key('offline-banner')), findsNothing);
    sync.emit(const SyncStatus(phase: SyncPhase.offline));
    await tester.pump();
    expect(find.byKey(const Key('offline-banner')), findsOneWidget);
    sync.emit(const SyncStatus(phase: SyncPhase.idle));
    await tester.pump();
    expect(find.byKey(const Key('offline-banner')), findsNothing);
  });

  testWidgets('tapping the pill syncs and shows the error', (tester) async {
    final sync = await pumpShell(tester);
    sync.emit(const SyncStatus(phase: SyncPhase.error, error: 'Server said no'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sync-pill')));
    await tester.pump();
    expect(sync.runs, 1);
    expect(find.text('Server said no'), findsOneWidget);
  });

  testWidgets('pull to sync runs an exchange', (tester) async {
    final sync = await pumpShell(tester);
    await tester.fling(
        find.byKey(const ValueKey('placeholder:today')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(sync.runs, 1);
  });

  testWidgets('sign out from the account menu', (tester) async {
    var signedOut = 0;
    await pumpShell(tester, onSignOut: () async => signedOut++);
    await tester.tap(find.byKey(const Key('account-menu')));
    await tester.pumpAndSettle();
    expect(find.text('me@a.test'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(signedOut, 1);
  });
}
