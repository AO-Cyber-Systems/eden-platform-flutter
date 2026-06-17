import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';
import 'social_login_providers.dart';

class PlatformLoginScreen extends ConsumerStatefulWidget {
  final VoidCallback? onSignUpTap;
  final VoidCallback? onLoginSuccess;

  /// When true (the default, for back-compat), the "OR" divider and the
  /// Microsoft + Google SSO buttons are rendered below the email/password
  /// form. Pass `false` to render an email-only login form — used by
  /// products like politihub Navigators that do not expose SSO via the
  /// platform API.
  final bool showSsoButtons;

  const PlatformLoginScreen({
    super.key,
    this.onSignUpTap,
    this.onLoginSuccess,
    this.showSsoButtons = true,
  });

  @override
  ConsumerState<PlatformLoginScreen> createState() =>
      _PlatformLoginScreenState();
}

class _PlatformLoginScreenState extends ConsumerState<PlatformLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _loginWithSocial(String provider) async {
    setState(() { _loading = true; _error = null; });
    try {
      await ref.read(authProvider.notifier).loginWithSocial(provider);
      // loginWithSocial reports failures by setting AuthState.error WITHOUT
      // throwing — inspect the resulting state rather than navigating
      // optimistically (matches the password _login path).
      final auth = ref.read(authProvider);
      if (auth.isAuthenticated) {
        widget.onLoginSuccess?.call();
      } else {
        setState(() {
          _error = auth.errorMessage ?? 'Sign in failed. Please try again.';
        });
      }
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      if (mounted) {
        setState(() { _loading = false; });
      }
    }
  }

  Future<void> _login() async {
    // Client-side validation: don't fire a network round-trip (or clear the
    // form) when either field is empty — surface an inline message instead.
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Enter your email and password.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(email, password);
      // AuthNotifier.login() reports auth failures by setting
      // AuthState.error WITHOUT throwing, so we must inspect the resulting
      // state rather than assume the await completing means success. Only
      // invoke onLoginSuccess on a genuinely authenticated session;
      // otherwise surface the failure inline (previously the callback fired
      // unconditionally and the error was never shown to the user).
      final auth = ref.read(authProvider);
      if (auth.isAuthenticated) {
        widget.onLoginSuccess?.call();
      } else {
        setState(() {
          _error = auth.errorMessage ??
              'Sign in failed. Check your email and password and try again.';
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      // onLoginSuccess may navigate away (unmounting this screen) — guard
      // the trailing setState so it doesn't throw post-dispose.
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'eden-login-screen',
      explicitChildNodes: true,
      child: Scaffold(
      body: Center(
        // Scrollable so a tall error banner or the on-screen keyboard never
        // overflows the form (RenderFlex bottom-overflow). Center keeps it
        // vertically centered while the content is shorter than the viewport.
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Welcome back',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in to your account',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      // Foreground for an errorContainer surface is
                      // onErrorContainer — using `error` here renders
                      // red-on-red (invisible) under brand themes whose
                      // error / errorContainer roles are close in hue
                      // (e.g. EdenTheme red brand).
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Semantics(
                  identifier: 'eden-login-email',
                  textField: true,
                  child: EdenInput(
                    controller: _emailController,
                    label: 'Email',
                    keyboardType: TextInputType.emailAddress,
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  identifier: 'eden-login-password',
                  textField: true,
                  child: EdenInput(
                    controller: _passwordController,
                    label: 'Password',
                    obscureText: true,
                  ),
                ),
                const SizedBox(height: 24),
                Semantics(
                  identifier: 'eden-login-submit',
                  button: true,
                  child: EdenButton(
                    onPressed: _loading ? null : _login,
                    label: _loading ? 'Signing in...' : 'Sign in',
                  ),
                ),
                if (widget.showSsoButtons) ...[
                  const SizedBox(height: 24),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('OR', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 24),
                  // Consumer social login (SOCIAL-06): five "Continue with"
                  // providers, each driving AuthNotifier.loginWithSocial via
                  // the cross-platform flutter_web_auth_2 flow. Replaces the
                  // former enterprise Microsoft/Google SSO buttons.
                  for (final p in kSocialLoginProviders) ...[
                    Semantics(
                      identifier: 'eden-login-social-${p.id}',
                      button: true,
                      child: OutlinedButton.icon(
                        onPressed:
                            _loading ? null : () => _loginWithSocial(p.id),
                        icon: Icon(p.icon, size: 20),
                        label: Text('Continue with ${p.label}'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),
                ],
                Semantics(
                  identifier: 'eden-login-signup-link',
                  button: true,
                  child: TextButton(
                    onPressed: widget.onSignUpTap,
                    child: const Text("Don't have an account? Sign up"),
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
