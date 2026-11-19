// Password sign-in (docs/api.md §Authentication, the `ot login` flow through
// AccountManager): email and password, then a two-factor code or recovery
// code when the account has one; rate limits and wrong credentials named.

import 'package:material_ui/material_ui.dart';

import '../../data/account.dart';
import '../../data/api.dart';
import '../theme.dart';
import '../tokens.dart';
import 'setup.dart' show Notice, NoticeTone;

class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.accounts,
    required this.origin,
    required this.onSignedIn,
    this.onChangeServer,
    this.insecure = false,
  });

  final AccountManager accounts;
  final String origin;
  final bool insecure;
  final Future<void> Function(AccountState account) onSignedIn;
  final VoidCallback? onChangeServer;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _mfa = false;
  bool _recovery = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AccountState account;
      if (_mfa) {
        final code = _code.text.trim();
        account = await widget.accounts.completeMfa(
          code: _recovery ? null : code,
          recoveryCode: _recovery ? code : null,
        );
      } else {
        final step = await widget.accounts.signInWithPassword(
          serverUrl: widget.origin,
          email: _email.text.trim(),
          password: _password.text,
        );
        switch (step) {
          case MfaRequired():
            if (!mounted) return;
            setState(() {
              _busy = false;
              _mfa = true;
            });
            return;
          case SignedIn(:final account):
            await widget.onSignedIn(account);
            return;
        }
      }
      await widget.onSignedIn(account);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // An expired or exhausted challenge: start over with the password.
        if (_mfa && e is UnauthorizedError && e.code == 'mfa_challenge_invalid') {
          _mfa = false;
          _code.clear();
        }
        _error = signInErrorMessage(e, mfa: _mfa);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
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
                  Text(_mfa ? 'Two-factor authentication' : 'Sign in',
                      style: OtType.h1.copyWith(color: c.textStrong)),
                  const SizedBox(height: 8),
                  Text(
                    _mfa
                        ? (_recovery
                            ? 'Enter one of your recovery codes.'
                            : 'Enter the code from your authenticator app.')
                        : widget.origin,
                    style: OtType.body.copyWith(color: c.muted),
                  ),
                  if (widget.insecure && !_mfa) ...[
                    const SizedBox(height: 12),
                    const Notice(
                      tone: NoticeTone.warning,
                      text: 'Not encrypted: your password is sent in plain text.',
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (!_mfa) ..._passwordFields() else ..._mfaFields(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Notice(key: const Key('sign-in-error'), tone: NoticeTone.danger, text: _error!),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('sign-in-submit'),
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? 'Signing in…' : (_mfa ? 'Verify' : 'Sign in')),
                  ),
                  const SizedBox(height: 8),
                  if (_mfa)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _recovery = !_recovery;
                                _code.clear();
                                _error = null;
                              }),
                      child: Text(_recovery ? 'Use an authenticator code' : 'Use a recovery code'),
                    )
                  else if (widget.onChangeServer != null)
                    TextButton(
                      key: const Key('sign-in-change-server'),
                      onPressed: _busy ? null : widget.onChangeServer,
                      child: const Text('Change server'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _passwordFields() => [
        TextField(
          key: const Key('sign-in-email'),
          controller: _email,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('sign-in-password'),
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.go,
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _submit(),
        ),
      ];

  List<Widget> _mfaFields() => [
        TextField(
          key: const Key('sign-in-code'),
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          autocorrect: false,
          keyboardType: _recovery ? TextInputType.text : TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textInputAction: TextInputAction.go,
          decoration: InputDecoration(labelText: _recovery ? 'Recovery code' : 'Code'),
          onSubmitted: (_) => _submit(),
        ),
      ];
}

/// The message for a failed sign-in step ([mfa]: the second-factor step).
String signInErrorMessage(Object e, {required bool mfa}) {
  if (e is RateLimitedError) {
    final wait = _wait(e.retryAfter);
    return e.code == 'account_locked'
        ? 'Too many failed attempts on this account. Try again $wait.'
        : 'Too many attempts from this network. Try again $wait.';
  }
  if (e is UnauthorizedError) {
    return switch (e.code) {
      'mfa_challenge_invalid' => 'The sign-in expired. Enter your password again.',
      'mfa_code_invalid' => 'That code is not right. Try the current one.',
      _ => mfa ? 'That code is not right. Try the current one.' : 'Wrong email or password.',
    };
  }
  if (e is ApiError) {
    if (e.code == 'mfa_enrolment_required') {
      return 'This server requires two-factor authentication. '
          'Set it up in the web app, then sign in here.';
    }
    return 'The server refused the sign-in: ${e.message.isEmpty ? e.code : e.message}';
  }
  if (e is NetworkError) return 'No answer from the server. Check your connection.';
  return 'Sign-in failed: $e';
}

String _wait(Duration? d) {
  if (d == null) return 'in a few minutes';
  if (d.inSeconds < 60) return 'in ${d.inSeconds < 1 ? 1 : d.inSeconds} s';
  final min = (d.inSeconds / 60).ceil();
  return 'in $min min';
}
