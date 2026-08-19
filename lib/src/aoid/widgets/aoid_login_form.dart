// AoidLoginForm — SEALED.
//
// This widget owns its own text controllers and posts the password DIRECTLY to
// the AOID issuer over TLS. There is deliberately NO parameter through which
// app-owned Dart can observe the value: no per-keystroke change callback, no
// value-bearing submit callback, no caller-supplied text controller, no
// caller-supplied focus node, no input formatters, no builder, no public State
// and no app-declarable key that could name one.
//
// The containment mechanism is the ABSENCE of API. A widget cannot leak a value
// it never hands out, so there is nothing here to get right at runtime and
// nothing to forget to guard.
//
// A "convenience" API letting an app supply its own password field defeats
// The issuer containment guarantee and must not be built.
//
// Gate: test/aoid/widgets/sealed_form_no_leak_test.dart — a source-level test,
// because the property is the absence of a member and no runtime assertion can
// observe one of those. Transport proof:
// test/aoid/widgets/aoid_login_form_transport_test.dart, which enters a
// password, submits, and asserts the captured request carried it to the AOID
// issuer host and explicitly NOT to the consuming app's own backend.
//
// WHY THERE IS NO RIVERPOD PROVIDER HERE, AND WHY THAT IS A DECISION.
// riverpod 3's `ProviderContainer.defaultRetry` is a FALLBACK, not an opt-in:
// a provider whose build throws an ordinary Exception is retried 10 times over
// a 38.2-second window, and each retry re-enters AsyncLoading. Since
// `AsyncValue.when()` tests `isLoading` before `hasError`, an error arm is
// unreachable for those 38 seconds — a failed credential submit would render a
// spinner rather than a result. That is the wrong behaviour for any auth
// surface, and here it is worse than cosmetic: the issuer's `MaxAttempts = 5` is
// DURABLE and carried forward on handle rotation, so ten automatic retries
// would burn a ceremony the user could still have completed. This form
// therefore drives AoidNativeFlow directly and rebuilds with setState.
// AoidNativeFlow itself folds every refusal into a state rather than throwing
// (see its `_step`), so there is no exception for a retry policy to act on
// even if one were introduced later.

import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';

import '../flow/aoid_native_flow.dart';
import 'aoid_login_theme.dart';

/// Key on the AOCyber gold accent rule, so a test can sample the colour the
/// ambient theme produced. Not an input: nothing can be passed in through it.
const kAoidAccentRuleKey = ValueKey<String>('aoid.login.accent-rule');

/// The sealed AOID password step.
///
/// ```dart
/// final flow = AoidNativeFlow(client:..., clientId:..., tenantId:...,
///                             redirectUri:...);
/// await flow.begin(codeChallenge: pkce.challenge);
/// //...
/// AoidLoginForm(controller: flow);
/// ```
///
/// The host app calls [AoidNativeFlow.begin] (it owns the PKCE verifier it will
/// need later to spend the code) and then hands the flow to this widget. From
/// that point the credential never enters app-owned Dart.
class AoidLoginForm extends StatefulWidget {
  const AoidLoginForm({
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
  State<AoidLoginForm> createState() => _AoidLoginFormState();
}

// PRIVATE, and that is load-bearing rather than stylistic: a public State class
// can be named by an app-declared key, whose `.currentState` reaches every
// private member on it — including the controller holding the plaintext. Making
// the type unnameable outside this library closes that path structurally.
class _AoidLoginFormState extends State<AoidLoginForm> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    // BEST-EFFORT ONLY — this is not erasure and must not be documented as if
    // it were. Dart cannot zero a String: `clear()` drops the controller's
    // reference to the text, but the bytes stay wherever the VM put them until
    // the collector reclaims them, and an immutable String cannot be
    // overwritten in place. It is still worth doing, because it shortens the
    // window in which a heap snapshot reaches the value through a live object.
    _passwordCtrl.clear();
    _passwordCtrl.dispose();
    _emailCtrl.clear();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      // THE CONTAINMENT BOUNDARY. The plaintext exists in the argument
      // expression below and in the request body, and nowhere else: it is never
      // assigned to a field, never written to a log, never interpolated into an
      // exception message, and never passed to anything the embedding app
      // supplied. `submitPassword` puts it straight on the wire to AOID.
      //
      // The email is passed RAW. AOID normalises internally exactly as its own
      // password step does; normalising here too would key a DIFFERENT
      // rate-limit bucket than the factor actually consumes.
      await widget.controller.submitPassword(
        email: _emailCtrl.text,
        password: _passwordCtrl.text,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Fixed, outcome-independent copy.
  ///
  /// Every message here comes from a closed vocabulary, and nothing in it is
  /// built from request input. That is not only a D3 rule — AOID answers an
  /// unknown email, a wrong password, an account with no password credential
  /// and a locked account BYTE-IDENTICALLY (re-proved over real HTTP by
  /// deliberately lossy). Manufacturing a richer reason in UI copy would reconstruct the
  /// account-existence oracle the issuer spent real effort removing.
  String? _notice() {
    final state = widget.controller.state;
    if (state is AoidFlowAwaitingFactor && state.lastAttemptRejected) {
      return 'That did not work. Check your details and try again.';
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
    if (state is AoidFlowRedirectRequired) {
      // NOT an error: social IdPs, PIV/CAC and the
      // restrictive isolation tiers all finish in a system browser.
      return 'Continue in your browser to finish signing in.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final copy = widget.theme;
    final notice = _notice();

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (copy.brandMark != null) ...[
            copy.brandMark!,
            const SizedBox(height: 24),
          ],
          if (copy.showGoldAccentRule) ...[
            // The AOCyber editorial device: a short rule in the brand accent
            // directly above the title. The colour is READ FROM THE AMBIENT
            // THEME — `colorScheme.primary` is EdenTheme.brandColor, which
            // defaults to EdenColors.gold — so a host that rebranded EdenTheme
            // gets its own accent instead of ours.
            Container(
              key: kAoidAccentRuleKey,
              width: 140,
              height: 3,
              color: colors.primary,
            ),
            const SizedBox(height: 16),
          ],
          Text(copy.headline, style: theme.textTheme.headlineSmall),
          if (copy.relyingPartyName.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'to continue to ${copy.relyingPartyName}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 24),
          EdenInput(
            controller: _emailCtrl,
            label: copy.emailLabel,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.username],
            enabled: !_submitting,
            // No change callback. The app is not told what is typed here
            // either: the identifier is not a secret, but a form that reported
            // one field and not the other would invite the "just one more"
            // parameter this design exists to refuse.
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          EdenInput(
            controller: _passwordCtrl,
            label: copy.passwordLabel,
            obscureText: true,
            // The OS password manager is a SINK, not a leak to app Dart —
            // dropping this makes the form worse, not safer.
            autofillHints: const [AutofillHints.password],
            enabled: !_submitting,
            // The value is DISCARDED here on purpose: this only reports that
            // the user pressed return. `(v) => _submit(v)` would be a leak one
            // character away, which is why the gate distinguishes this callback
            // from a public one of its own.
            onSubmitted: (_) => _submit(),
          ),
          if (notice != null) ...[
            const SizedBox(height: 16),
            Text(
              notice,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
          const SizedBox(height: 24),
          EdenButton(
            label: copy.submitLabel,
            onPressed: _submitting ? null : _submit,
            loading: _submitting,
            fullWidth: true,
          ),
        ],
      ),
    );
  }
}
