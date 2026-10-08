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
//
// THE PASSKEY ENTRY IS INSIDE THE SEAL.
// "Sign in with a passkey" is part of this widget, not something an app wires
// up: it adds no constructor parameter, no callback and no authenticator
// argument. The form asks the SDK's own resolver for the platform
// authenticator and hands it to `AoidNativeFlow.signInWithPasskey`, which
// runs the whole ceremony — challenge, OS sheet, assertion, submit — and
// answers a closed `AoidPasskeyOutcome`. The assertion is produced and
// consumed inside the flow; this widget never holds it, never names it, and
// could not log it if it tried (sealed_form_no_leak_test.dart, test 8).
//
// WHY THE BUTTON STARTS HIDDEN. `isSupported()` is asynchronous, and the
// button is rendered only once it has answered `true` AND the issuer
// advertised `webauthn_discoverable` at the `started` stage
// (`controller.canUsePasskey`). Rendering it optimistically and hiding it on a
// `false` would show, for a frame or more, a button that could be tapped and
// could not work — and a button that cannot work is never shown. So on
// web, Android, Windows, Linux, iOS < 16, macOS < 13, and on an app that did
// not link the native half, it simply never appears.

import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';

import '../flow/aoid_native_flow.dart';
import '../flow/aoid_passkey_outcome.dart';
import '../passkey/aoid_passkey_resolver.dart';
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

  /// FALSE UNTIL PROVEN. Set only when the platform authenticator answered
  /// `isSupported() == true`; see the file header for why it never starts
  /// optimistic.
  bool _passkeySupported = false;

  /// A passkey attempt is in flight (challenge, OS sheet, assertion, and the
  /// restart the flow performs after any attempt that did not complete).
  bool _passkeyBusy = false;

  /// The last passkey attempt's outcome. Drives the passkey notice; cleared by
  /// any new submit. Only the closed outcome — never anything the
  /// authenticator produced.
  AoidPasskeyOutcome? _lastPasskey;

  /// The last passkey attempt THREW instead of answering an outcome: a breach
  /// of the authenticator's never-throws contract. See
  /// [_signInWithPasskey].
  bool _passkeyThrew = false;

  /// Either path in flight locks the whole form: both fields and both buttons.
  bool get _busy => _submitting || _passkeyBusy;

  @override
  void initState() {
    super.initState();
    _probePasskeySupport();
  }

  Future<void> _probePasskeySupport() async {
    var supported = false;
    try {
      supported = await resolveAoidPasskeyAuthenticator().isSupported();
    } catch (_, stack) {
      // isSupported never throws by contract. If it does, the button
      // stays hidden — the safe answer — and the breach is reported with a
      // fixed message. See _reportAuthenticatorBreach.
      _reportAuthenticatorBreach(stack, 'while probing passkey support');
    }
    // The answer may land after dispose.
    if (mounted && supported) setState(() => _passkeySupported = true);
  }

  /// Reports a broken [AoidPasskeyAuthenticator] contract through
  /// [FlutterError.reportError], so the bug is visible in every build mode —
  /// in debug, and in a host's crash reporting in release.
  ///
  /// The report carries a FIXED message and the stack trace (code
  /// locations only). The thrown object itself is never bound, so neither
  /// its message nor anything it holds can reach a sink.
  static void _reportAuthenticatorBreach(StackTrace stack, String during) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: FlutterError(
          'AoidPasskeyAuthenticator threw. Its contract is to answer, never '
          'to throw.',
        ),
        stack: stack,
        library: 'eden_platform_flutter',
        context: ErrorDescription(during),
      ),
    );
  }

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
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      // A password attempt supersedes whatever the last passkey attempt said.
      _lastPasskey = null;
      _passkeyThrew = false;
    });
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

  /// The passkey path. The widget hands the flow the SDK's own authenticator
  /// and gets back ONLY a closed [AoidPasskeyOutcome]: the challenge, the OS
  /// sheet, the assertion and its submission all happen inside
  /// `AoidNativeFlow.signInWithPasskey`. Nothing here sees, stores or names
  /// the assertion.
  ///
  /// NO RETRY, for the same reason the password path has none: AOID's
  /// `MaxAttempts = 5` is durable across rotation.
  ///
  /// # A THROWING AUTHENTICATOR
  ///
  /// The authenticator's contract is to answer a closed attempt and
  /// never throw, and the platform implementation enforces it, so
  /// `signInWithPasskey` does not catch. A throw is therefore a programming
  /// error — but if one escaped this async tap handler, the user would see the
  /// button vanish (the challenge already moved AOID to `webauthn_pending`)
  /// with no word of explanation. So the form defends:
  ///
  ///   * the form is unlocked and shows a fixed sentence from the existing
  ///     vocabulary, `Sign-in could not be completed.` — NOT the `failed`
  ///     sentence, whose "use your password instead" would be untrue: after a
  ///     throw the flow has not restarted, and only the flow can;
  ///   * nothing about the thrown object is shown, logged or kept (it is not
  ///     even bound to a name), so no OS or authenticator text can surface;
  ///   * the breach is NOT masked: it is reported with a fixed message and
  ///     the stack trace (see [_reportAuthenticatorBreach]).
  Future<void> _signInWithPasskey() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _passkeyBusy = true;
      _lastPasskey = null;
      _passkeyThrew = false;
    });
    AoidPasskeyOutcome? outcome;
    try {
      outcome = await widget.controller.signInWithPasskey(
        resolveAoidPasskeyAuthenticator(),
      );
    } catch (_, stack) {
      // Contract breach: see the doc comment. `outcome` stays null.
      _reportAuthenticatorBreach(stack, 'while signing in with a passkey');
    }
    if (!mounted) return;
    setState(() {
      _passkeyBusy = false;
      _lastPasskey = outcome;
      _passkeyThrew = outcome == null;
    });
  }

  /// The passkey path's own copy — a closed vocabulary, built from nothing the
  /// authenticator or the issuer said.
  ///
  /// Only `rejected`, `unavailable` and `failed` speak. `cancelled` is SILENT:
  /// Apple reports "dismissed the sheet" and "has no passkey here" as the same
  /// error, and a different word for either would be wrong half the time and
  /// would hint whether an account holds a passkey. `rejected` is the SAME
  /// sentence as a rejected password, on purpose — it is exactly as opaque.
  /// `completed` and `interrupted` defer to the state-derived copy below.
  String? _passkeyNotice() {
    if (_passkeyThrew) return 'Sign-in could not be completed.';
    return switch (_lastPasskey) {
      AoidPasskeyOutcome.rejected =>
        'That did not work. Check your details and try again.',
      AoidPasskeyOutcome.unavailable =>
        'Passkey sign-in is not available on this device right now. '
            'Use your password instead.',
      AoidPasskeyOutcome.failed =>
        'Passkey sign-in could not be completed. Use your password instead.',
      AoidPasskeyOutcome.completed ||
      AoidPasskeyOutcome.cancelled ||
      AoidPasskeyOutcome.interrupted ||
      null => null,
    };
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
    // A speaking passkey outcome takes precedence; it is cleared by the next
    // submit of either kind.
    final passkey = _passkeyNotice();
    if (passkey != null) return passkey;
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
    final busy = _busy;
    // Proven support AND an advertised, still-open `started` stage — or this
    // very button's attempt in flight, so an incidental rebuild while AOID
    // sits at `webauthn_pending` does not make it vanish under the OS sheet.
    final offerPasskey =
        _passkeySupported && (_passkeyBusy || widget.controller.canUsePasskey);

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
            enabled: !busy,
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
            enabled: !busy,
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
            onPressed: busy ? null : _submit,
            loading: _submitting,
            fullWidth: true,
          ),
          if (offerPasskey) ...[
            const SizedBox(height: 12),
            // Below the password submit, in eden-ui's `secondary` variant: an
            // alternative, not the primary call to action. Colours come from
            // eden-ui's own tokens; nothing is hardcoded here.
            EdenButton(
              label: copy.passkeyLabel,
              variant: EdenButtonVariant.secondary,
              onPressed: busy ? null : _signInWithPasskey,
              loading: _passkeyBusy,
              fullWidth: true,
            ),
          ],
        ],
      ),
    );
  }
}
