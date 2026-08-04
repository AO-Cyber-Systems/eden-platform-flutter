// THE TYPE THAT KEEPS A TENANT DENIAL FROM BECOMING A SIGN-OUT.
//
// Riverpod-free and Flutter-free. It imports one sibling for the retry policy's
// transport case and nothing else.

import '../transport/aoid_error.dart';

/// A tenant switch was **DENIED**. This is a PERMISSION answer, not a SESSION
/// answer, and it MUST NOT be treated as an authentication failure.
///
/// AOID returns a generic `invalid_grant` for a non-membership switch (aoid
/// `internal/oauth/service.go:906-913`). If that reaches
/// `AuthNotifier.restoreSession`'s `AuthError` path (`auth_provider.dart`
/// :410-413 -> `_clearPersistedTokens()` + `unauthenticated`) or a Dio 401
/// interceptor's `forceUnauthenticated()` (AODex
/// `lib/src/features/auth/application/auth_service.dart:139-147`), the user is
/// **SIGNED OUT for asking about a workspace they are not in**. That is the
/// single most likely bug in SDK-07, and this type exists to make it
/// unrepresentable.
///
/// It deliberately does NOT extend `AuthError` or `AoidError` and shares no
/// supertype with them beyond `Exception`, so a handler written as
/// `if (e is AuthError || e is AoidError) signOut()` — which is what both real
/// paths reduce to — cannot catch it by accident.
///
/// ## It carries NO detail, and that is load-bearing
///
/// `service.go:906-913` withholds the distinction between "not a member" and
/// "bad token" so the endpoint is not a membership oracle. **Do not add a
/// `reason`, a `cause`, a slug, or a second message per branch** — that
/// rebuilds the oracle the server spent code removing. Note in particular that
/// [message] does not say *"you are not a member"*: the client cannot know that
/// (see [AoidTenantDenied] disambiguation below), and asserting it would invent
/// detail the server refused to give.
///
/// ## How a denial is told apart from an expiry — and the limit of it
///
/// It cannot be told apart from the RESPONSE: a denied switch and a genuinely
/// dead refresh token are byte-identical, deliberately. `AoidTokenClient`
/// therefore disambiguates by **REQUEST CONTEXT**: a failure on a call that
/// CARRIED `active_tenant` is a denial candidate; the same failure WITHOUT it
/// is an authentication failure.
///
/// The residual ambiguity is real and is resolved in the SAFE direction: a
/// refresh token that expires *during* a switch is reported as
/// [AoidTenantDenied], so the user is NOT signed out when they should have
/// been. That self-corrects — the next ORDINARY refresh carries no
/// `active_tenant`, so it surfaces as `AoidError` and the normal sign-out
/// happens. Failing the other way would sign people out of a live session,
/// which is the defect this whole TRD exists to prevent.
final class AoidTenantDenied implements Exception {
  const AoidTenantDenied();

  /// FIXED VOCABULARY, following `aoid_error.dart`. One message, forever, so
  /// two causes cannot be told apart here either.
  ///
  /// Phrased as an OUTCOME rather than a verdict: the switch did not happen.
  /// It does not claim the user lacks access, because the client does not know
  /// that.
  String get message => 'that workspace could not be selected';

  @override
  String toString() => 'AoidTenantDenied: $message';

  @override
  bool operator ==(Object other) => other is AoidTenantDenied;

  @override
  int get hashCode => (AoidTenantDenied).hashCode;
}

/// The retry policy for any provider that surfaces a tenant switch.
///
/// **Pass this as riverpod's `retry:` argument.** Its signature is exactly
/// riverpod's `Duration? Function(int retryCount, Object error)`, matched
/// structurally so this library does not have to import riverpod.
///
/// ## Why it is needed at all
///
/// riverpod 3 retries a failed provider **automatically**:
/// `ProviderContainer.defaultRetry` is the *fallback*, not an opt-in
/// (`element.dart:685`), giving **10 attempts, 200ms doubling to 6400ms — a
/// 38.2-second window** — and it declines only for `ProviderException` and
/// `Error`. Dart's `Error` means *programming* faults, so **every ordinary
/// `Exception` is retried**, [AoidTenantDenied] included.
///
/// Two consequences, both bad here:
///
/// * `AsyncValue.when()` tests `isLoading` FIRST (`async_value.dart:250`), and
///   a pending retry emits an `AsyncLoading` that CARRIES the error — so the
///   `error:` arm is **unreachable for the whole 38 seconds**. The user sees a
///   spinner, not a refusal, with no retry affordance.
/// * Ten silent re-probes of a workspace the user is not in is ten
///   `auth.active_tenant.denied` audit rows per tap.
///
/// ## The decision, stated
///
/// [AoidTenantDenied] stays an `Exception` rather than becoming an `Error`:
/// it is a legitimate runtime outcome, not a programming fault, and making it
/// an `Error` would slip past every `on Exception` handler a consumer has. The
/// retry hazard is closed HERE instead — refusals are never retried, while a
/// genuine transport blip still gets a bounded 3 attempts.
Duration? aoidTenantSwitchRetry(int retryCount, Object error) {
  // A refusal. Retrying it cannot change the answer.
  if (error is AoidTenantDenied) return null;
  // An AOID authentication-layer refusal. Also an answer, not a blip.
  if (error is AoidError) return null;
  // Everything else — a dead socket, a 503 from a replica, a 500 — may
  // genuinely succeed on a second attempt. Bounded, so the error is still
  // reachable in about a second rather than 38.
  if (retryCount >= 3) return null;
  return Duration(milliseconds: 200 * (1 << retryCount));
}
