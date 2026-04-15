import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

class PlatformLoginScreen extends ConsumerStatefulWidget {
  final VoidCallback? onSignUpTap;
  final VoidCallback? onLoginSuccess;

  const PlatformLoginScreen({
    super.key,
    this.onSignUpTap,
    this.onLoginSuccess,
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

  Future<void> _loginWithSSO(String provider) async {
    setState(() { _loading = true; _error = null; });
    try {
      await ref.read(authProvider.notifier).loginWithSSO(provider);
      widget.onLoginSuccess?.call();
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(
            _emailController.text.trim(),
            _passwordController.text,
          );
      widget.onLoginSuccess?.call();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'eden-login-screen',
      explicitChildNodes: true,
      child: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
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
                OutlinedButton.icon(
                  onPressed: _loading ? null : () => _loginWithSSO('microsoft'),
                  icon: const Icon(Icons.window, size: 20),
                  label: const Text('Sign in with Microsoft'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _loading ? null : () => _loginWithSSO('google'),
                  icon: const Icon(Icons.g_mobiledata, size: 24),
                  label: const Text('Sign in with Google'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 16),
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
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
