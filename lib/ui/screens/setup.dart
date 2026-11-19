// The first-run screen: the server address and its health check, with the
// rules of the mobile apps (mobile/README.md, "How it fits together"): https,
// or http only for local addresses after a warning; a failed check names why.

import 'package:material_ui/material_ui.dart';

import '../../data/api.dart';
import '../server_address.dart';
import '../theme.dart';
import '../tokens.dart';

typedef OnConnected = void Function(String origin, bool insecure, HealthInfo health);

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.healthCheck,
    required this.onConnected,
    this.initialAddress,
    this.notice,
  });

  final HealthCheck healthCheck;
  final OnConnected onConnected;
  final String? initialAddress;
  final String? notice;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _address = TextEditingController(text: widget.initialAddress ?? '');
  bool _busy = false;
  String? _error;

  /// An https address to offer instead of a refused public http one.
  String? _suggestion;

  /// The local http origin the user was warned about; connecting again with
  /// the same origin goes ahead.
  String? _warnedInsecure;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _edited(String _) {
    if (_error != null || _suggestion != null || _warnedInsecure != null) {
      setState(() {
        _error = null;
        _suggestion = null;
        _warnedInsecure = null;
      });
    }
  }

  Future<void> _connect() async {
    final parsed = ServerAddress.parse(_address.text);
    switch (parsed) {
      case InvalidAddress():
        setState(() => _error =
            'That is not a server address. Type the address you open OpenTodo at, like todo.example.com.');
        return;
      case NeedsHttps(:final suggestion):
        setState(() {
          _error = 'Plain http is allowed only for this device and the local network. '
              'Use the https address instead.';
          _suggestion = suggestion;
        });
        return;
      case ValidAddress(:final origin, :final insecure):
        if (insecure && _warnedInsecure != origin) {
          setState(() => _warnedInsecure = origin);
          return;
        }
        setState(() {
          _busy = true;
          _error = null;
          _suggestion = null;
        });
        try {
          final health = await widget.healthCheck(origin);
          if (!mounted) return;
          setState(() => _busy = false);
          widget.onConnected(origin, insecure, health);
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = healthMessage(classifyHealthError(e), origin);
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
    final warned = _warnedInsecure;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Connect to your server',
                      style: OtType.h1.copyWith(color: c.textStrong)),
                  const SizedBox(height: 8),
                  Text('The address you open OpenTodo at in the browser.',
                      style: OtType.body.copyWith(color: c.muted)),
                  if (widget.notice != null) ...[
                    const SizedBox(height: 12),
                    Notice(text: widget.notice!, tone: NoticeTone.info),
                  ],
                  const SizedBox(height: 20),
                  TextField(
                    key: const Key('setup-address'),
                    controller: _address,
                    enabled: !_busy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'todo.example.com',
                    ),
                    onChanged: _edited,
                    onSubmitted: (_) => _connect(),
                  ),
                  if (warned != null) ...[
                    const SizedBox(height: 12),
                    Notice(
                      key: const Key('setup-insecure-warning'),
                      tone: NoticeTone.warning,
                      text: '$warned is not encrypted: anyone on the network can read what is '
                          'sent, your password included. Use it only on a network you trust.',
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Notice(key: const Key('setup-error'), tone: NoticeTone.danger, text: _error!),
                  ],
                  if (_suggestion != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _address.text = _suggestion!;
                          _suggestion = null;
                          _error = null;
                        }),
                        child: Text('Use ${_suggestion!}'),
                      ),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('setup-connect'),
                    onPressed: _busy ? null : _connect,
                    child: Text(_busy
                        ? 'Checking…'
                        : warned != null
                            ? 'Connect anyway'
                            : 'Connect'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The named failure of a health check.
String healthMessage(HealthProblem problem, String origin) => switch (problem) {
      HealthProblem.noNetwork =>
        'No answer from $origin. Check the address and your connection.',
      HealthProblem.notOpenTodo =>
        '$origin answered, but it is not an OpenTodo server. Check the address.',
      HealthProblem.untrusted =>
        'The certificate of $origin is not trusted, so the app will not connect. '
            'Install a trusted certificate on the server.',
    };

enum NoticeTone { info, warning, danger }

/// A tinted message box for errors, warnings and notes on forms.
class Notice extends StatelessWidget {
  const Notice({super.key, required this.text, this.tone = NoticeTone.info});

  final String text;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
    final (bg, fg) = switch (tone) {
      NoticeTone.info => (c.infoSoft, c.infoSoftText),
      NoticeTone.warning => (c.warningSoft, c.warningSoftText),
      NoticeTone.danger => (c.dangerSoft, c.dangerSoftText),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(OtRadii.control),
      ),
      child: Text(text, style: OtType.body.copyWith(color: fg)),
    );
  }
}
