// Presentation inputs for the sealed AOID forms (50-CONTEXT.md D3, TRD 50-11).
//
// EVERY FIELD ON THIS STRUCT IS AN INPUT. There is deliberately no field of a
// function type — no builder, no callback, nothing that could RETURN user
// input — and none may be added. A presentation struct that can hand a value
// back is a credential tap wearing a data structure's clothes, and it is the
// most plausible way this design decays: nobody adds `String Function()
// revealPassword`, they add a "small" builder for one piece of chrome, and the
// builder grows a `value` argument six months later.
//
// Gate: test/aoid/widgets/sealed_form_no_leak_test.dart, test 6, which reads
// the declared type of every `final` field here and fails on any that names a
// function type. Its positive control plants `String Function() reveal;` and
// proves the predicate fires.
//
// COLOURS AND FONTS ARE NOT HERE, ON PURPOSE. Flutter theming already flows
// down through an InheritedWidget, so the forms read `Theme.of(context)` and
// inherit whatever EdenTheme the host app installed — AOCyber gold
// (`EdenTheme.brandColor` defaults to `EdenColors.gold`) unless the host says
// otherwise. Adding colour parameters here would both grow the surface and let
// an embedding app drift away from its own brand.

import 'package:flutter/widgets.dart';

/// Copy and chrome for [AoidLoginForm] and [AoidMfaForm].
///
/// Only strings, flags and one pre-built [Widget]. See the file header for why
/// that restriction is the point rather than an accident.
@immutable
class AoidLoginTheme {
  const AoidLoginTheme({
    this.headline = 'Sign in',
    this.relyingPartyName = '',
    this.brandMark,
    this.showGoldAccentRule = true,
    this.submitLabel = 'Sign in',
    this.emailLabel = 'Email',
    this.passwordLabel = 'Password',
    this.mfaHeadline = 'Two-factor authentication',
    this.otpLabel = 'Authentication code',
    this.mfaSubmitLabel = 'Verify',
  });

  /// Title above the password step.
  final String headline;

  /// The application the user is signing in TO. Rendered as
  /// `to continue to <name>` beneath [headline]; omitted entirely when empty,
  /// because "to continue to " with nothing after it looks like a bug.
  final String relyingPartyName;

  /// An already-constructed logo widget, placed above the headline.
  ///
  /// A [Widget] and NOT a builder, deliberately. The app builds this BEFORE the
  /// form exists, so it can close over nothing the form knows — it cannot see a
  /// text controller, a field value or any state the form later acquires. A
  /// builder would instead run inside the form's own `build`, which is safe
  /// today and is exactly the parameter that later grows a `value` argument.
  final Widget? brandMark;

  /// Whether to draw the short gold rule above the headline.
  ///
  /// This is the AOCyber editorial device — a ~140x3 bar in the brand accent
  /// sitting directly above a title. The colour is read from the ambient theme
  /// (`colorScheme.primary`), never hardcoded, so a host that has rebranded
  /// EdenTheme gets its own accent rather than AOCyber gold.
  final bool showGoldAccentRule;

  /// Label on the password step's submit control.
  final String submitLabel;

  /// Label for the identifier field.
  final String emailLabel;

  /// Label for the password field.
  final String passwordLabel;

  /// Title above the second-factor step.
  final String mfaHeadline;

  /// Label for the TOTP / backup-code field.
  final String otpLabel;

  /// Label on the second-factor step's submit control.
  final String mfaSubmitLabel;
}
