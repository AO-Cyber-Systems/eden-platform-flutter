import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

class PlatformSignUpScreen extends ConsumerStatefulWidget {
  final VoidCallback? onLoginTap;
  final VoidCallback? onSignUpSuccess;

  const PlatformSignUpScreen({
    super.key,
    this.onLoginTap,
    this.onSignUpSuccess,
  });

  @override
  ConsumerState<PlatformSignUpScreen> createState() =>
      _PlatformSignUpScreenState();
}

class _PlatformSignUpScreenState extends ConsumerState<PlatformSignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  // EdenSecretField is value-driven, not controller-driven — see the same
  // note in login_screen.dart. This mirrors its internal controller.
  String _password = '';
  bool _loading = false;
  String? _error;

  Future<void> _signUp() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signUp(
            _emailController.text.trim(),
            _password,
            _nameController.text.trim(),
          );
      widget.onSignUpSuccess?.call();
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
      identifier: 'eden-signup-screen',
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
                  'Create an account',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Get started with Eden',
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
                  identifier: 'eden-signup-name',
                  textField: true,
                  child: EdenInput(
                    controller: _nameController,
                    label: 'Display Name',
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  identifier: 'eden-signup-email',
                  textField: true,
                  child: EdenInput(
                    controller: _emailController,
                    label: 'Email',
                    keyboardType: TextInputType.emailAddress,
                  ),
                ),
                const SizedBox(height: 16),
                // Accessible name supplied at the call site — EdenSecretField's
                // label is a sibling Text with no fold, so an unwrapped field is
                // announced with NO NAME (eden_input.dart:86-100 documents the same
                // defect for EdenInput). No `textField: true` (it would stack a
                // second node and emit two <input>s on web) and deliberately NO
                // MergeSemantics (it folds the reveal IconButton into the field's
                // node, costing the toggle its independent focus stop). See the
                // fuller note in login_screen.dart.
                Semantics(
                  identifier: 'eden-signup-password',
                  label: 'Password',
                  child: EdenSecretField(
                    value: _password,
                    label: 'Password',
                    // NO setState — see login_screen.dart for the caret rationale.
                    onChanged: (v) => _password = v,
                    // NO onCopy — it would render a copy button on a password.
                  ),
                ),
                const SizedBox(height: 24),
                Semantics(
                  identifier: 'eden-signup-submit',
                  button: true,
                  child: EdenButton(
                    onPressed: _loading ? null : _signUp,
                    label: _loading ? 'Creating account...' : 'Sign up',
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  identifier: 'eden-signup-login-link',
                  button: true,
                  child: TextButton(
                    onPressed: widget.onLoginTap,
                    child: const Text('Already have an account? Sign in'),
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
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }
}
