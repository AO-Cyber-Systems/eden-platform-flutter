// AoidMfaForm — SEALED.
//
// The same rules as AoidLoginForm, for the same reason: a TOTP code is a
// credential and a backup code is a long-lived one. This widget owns its own
// text controller and posts the code DIRECTLY to the AOID issuer. There is no
// per-keystroke change callback, no value-bearing submit callback, no
// caller-supplied text controller, no caller-supplied focus node, no input
// formatters, no builder, no public State and no app-declarable key that could
// name one.
//
// A "convenience" API letting an app supply its own code field defeats
// The issuer containment guarantee and must not be built.
//
// Gate: test/aoid/widgets/sealed_form_no_leak_test.dart (tests 3, 4 and 5).
//
// THE PICKER MUST TOLERATE AN EMPTY LIST, AND USUALLY GETS ONE.
// `AoidFlowAwaitingFactor.availableMethods` is empty until a factor has already
// succeeded: the issuer refuses to emit a per-identity method list before that,
// because doing so turns the endpoint into an enumeration oracle — ask for any
// address and the response tells you whether the account exists and how it is
// protected. So "no methods offered" is the NORMAL early state, not a
// degradation, and rendering an empty picker (or throwing on one) would be a
// bug in the common path rather than an edge case.

import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';

import '../flow/aoid_native_flow.dart';
import 'aoid_login_theme.dart';

/// Human labels for AOID's factor identifiers.
///
/// Unlisted values fall through to the identifier itself rather than being
/// hidden: AOID is a first-party issuer, and silently dropping a method the
/// user actually holds is worse than showing its wire name.
const _methodLabels = <String, String>{
  'totp': 'Authenticator app',
  'backup_code': 'Backup code',
  'sms': 'Text message',
  'email': 'Email code',
  'webauthn': 'Security key',
  'webauthn_discoverable': 'Security key',
};

/// Factors this form can actually collect — the ones that are a typed code.
///
/// AOID accepts a TOTP code and a backup code on the SAME `otp` field, so both
/// submit identically. A security key is not a typed code and is completed by
/// the platform authenticator path instead, so selecting it here
/// says so rather than offering a text box that cannot work.
const _codeMethods = <String>{'totp', 'backup_code', 'sms', 'email', 'mfa'};

/// The sealed AOID second-factor step.
class AoidMfaForm extends StatefulWidget {
  const AoidMfaForm({
    super.key,
    required this.controller,
    this.theme = const AoidLoginTheme(),
  });

  /// Drives the ceremony. Exposes step / next / availableMethods / outcome —
  /// NEVER the credential. (See `AoidNativeFlow`.)
  final AoidNativeFlow controller;

  /// Copy and chrome. Input-only; carries no function-typed field.
  final AoidLoginTheme theme;

  @override
  State<AoidMfaForm> createState() => _AoidMfaFormState();
}

// PRIVATE for the same structural reason as _AoidLoginFormState: an unnameable
// type cannot be reached through an app-declared key.
class _AoidMfaFormState extends State<AoidMfaForm> {
  final _otpCtrl = TextEditingController();

  bool _submitting = false;
  String? _selected;

  List<String> get _methods {
    final state = widget.controller.state;
    return state is AoidFlowAwaitingFactor ? state.availableMethods : const [];
  }

  /// The method the user is currently entering a code for.
  ///
  /// Falls back to the first offered method, and to `'totp'` when NOTHING is
  /// offered — which is the usual case before a factor has succeeded. The form
  /// still works then: AOID knows which factor it is waiting for, and the code
  /// goes to the same field regardless.
  String get _activeMethod {
    if (_selected != null) return _selected!;
    final methods = _methods;
    return methods.isEmpty ? 'totp' : methods.first;
  }

  @override
  void dispose() {
    // BEST-EFFORT ONLY, exactly as in AoidLoginForm — Dart cannot zero a
    // String, so this drops a reference rather than scrubbing memory. Do not
    // describe it as erasure.
    _otpCtrl.clear();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_codeMethods.contains(_activeMethod)) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      // THE CONTAINMENT BOUNDARY, as in AoidLoginForm: the code lives in this
      // argument expression and in the request body, and nowhere else.
      await widget.controller.submitOtp(_otpCtrl.text);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Fixed copy from a closed vocabulary. See the note in AoidLoginForm: a
  /// rejected second factor is reported without a reason on purpose.
  String? _notice() {
    final state = widget.controller.state;
    if (state is AoidFlowAwaitingFactor && state.lastAttemptRejected) {
      return 'That code was not accepted. Try again.';
    }
    if (state is AoidFlowRestartRequired) {
      return 'This sign-in session has ended. Start again.';
    }
    if (state is AoidFlowUnavailable) {
      return 'Sign-in is temporarily unavailable. Try again in a moment.';
    }
    if (state is AoidFlowFailed) {
      return 'Sign-in could not be completed.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final copy = widget.theme;
    final methods = _methods;
    final active = _activeMethod;
    final canType = _codeMethods.contains(active);
    final notice = _notice();

    // `AutofillHints.oneTimeCode` below is inert without an enclosing
    // AutofillGroup — the group is what commits the scope to the platform, and
    // AoidLoginForm has had one since it was written. This form did not, so the
    // OTP field advertised a hint nothing ever acted on.
    //
    // NO-LEAK CONTRACT: AutofillGroup is contract-compatible. It takes no
    // callback, exposes no value to app Dart, and adds nothing to this widget's
    // public surface — it only scopes the OS autofill sink, exactly as it does
    // in AoidLoginForm. The code still reaches the issuer only via `_submit`.
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (copy.showGoldAccentRule) ...[
            // Ambient accent, as in AoidLoginForm — read from the theme, never
            // hardcoded.
            Container(
              key: kAoidMfaAccentRuleKey,
              width: 140,
              height: 3,
              color: colors.primary,
            ),
            const SizedBox(height: 16),
          ],
          Text(copy.mfaHeadline, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 24),

          // Only render a picker when there is a CHOICE to make. An empty list is
          // the normal early state, and a single offered method is not a
          // choice — showing either as a picker is chrome pretending to be a
          // decision.
          if (methods.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final method in methods)
                  ChoiceChip(
                    label: Text(_methodLabels[method] ?? method),
                    selected: method == active,
                    onSelected: _submitting
                        ? null
                        : (_) => setState(() => _selected = method),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],

          if (canType)
            EdenInput(
              controller: _otpCtrl,
              label: copy.otpLabel,
              keyboardType: TextInputType.number,
              // A one-time code is an OS autofill sink too, and on iOS this is
              // what lifts the code out of the incoming message.
              autofillHints: const [AutofillHints.oneTimeCode],
              enabled: !_submitting,
              // Value DISCARDED — this only reports the return key. See the same
              // note in AoidLoginForm.
              onSubmitted: (_) => _submit(),
            )
          else
            Text(
              'Use your security key to continue.',
              style: theme.textTheme.bodyMedium,
            ),

          if (notice != null) ...[
            const SizedBox(height: 16),
            Text(
              notice,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],

          if (canType) ...[
            const SizedBox(height: 24),
            EdenButton(
              label: copy.mfaSubmitLabel,
              onPressed: _submitting ? null : _submit,
              loading: _submitting,
              fullWidth: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// Key on the MFA step's accent rule, so a test can sample the ambient colour.
const kAoidMfaAccentRuleKey = ValueKey<String>('aoid.mfa.accent-rule');
