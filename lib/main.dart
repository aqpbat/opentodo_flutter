import 'package:material_ui/material_ui.dart';

import 'ui/theme.dart';

void main() {
  runApp(const OpenTodoApp());
}

/// The app root: themes from the design tokens, following the system
/// light/dark preference like the web app. Navigation arrives in M3.2.
class OpenTodoApp extends StatelessWidget {
  const OpenTodoApp({super.key, this.home});

  /// The first screen; a placeholder until the app shell exists.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenTodo',
      debugShowCheckedModeBanner: false,
      theme: OtTheme.light,
      darkTheme: OtTheme.dark,
      themeMode: ThemeMode.system,
      home: home ?? const _PlaceholderHome(),
    );
  }
}

class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenTodo')),
      body: Center(
        child: Text('Nothing here yet', style: TextStyle(color: context.ot.muted)),
      ),
    );
  }
}
