import 'package:material_ui/material_ui.dart';

import 'ui/app.dart';
import 'ui/bootstrap.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(AppDeps.production());
  runApp(OpenTodoApp(home: AppRoot(controller: controller)));
}

/// The app root: themes from the design tokens, following the system
/// light/dark preference like the web app. [home] is the [AppRoot] in the
/// app (session restore → setup → sign-in → shell).
class OpenTodoApp extends StatelessWidget {
  const OpenTodoApp({super.key, this.home});

  /// The first screen; a placeholder when null (theme tests).
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
