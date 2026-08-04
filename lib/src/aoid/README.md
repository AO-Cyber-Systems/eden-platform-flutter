# The AOID module

The AOID identity client that ships inside `eden_platform_flutter`. AOID is AO Cyber's identity
provider; this module is the Flutter-side client for it.

**Everything here is imported from one place:**

```dart
import 'package:eden_platform_flutter/eden_platform.dart';
```

There is no `aoid.dart` and no `aoid_riverpod.dart`. Those two barrels existed only because
`flutter_riverpod` 2.x and 3.x could not coexist in one dependency graph, so the AOID surface was
split to keep a riverpod-free half available to 2.x consumers. **TRD 50-24 deleted both** once the
workspace-wide riverpod 3 alignment removed the version boundary that forced the split. Their 25
exported symbols all survive on `eden_platform.dart`; nothing was lost in the fold. The record of
how that happened is in [`doc/riverpod-3-migration.md`](../../../doc/riverpod-3-migration.md).

> Do not re-create either barrel. `test/aoid/eden_platform_surface_test.dart` asserts they are
> absent, because a half-applied fold is worse than either state.

The module's source is organised behind seven part-barrels under `lib/src/aoid/parts/` — `claims`,
`modes`, `native`, `storage`, `widgets`, `redirect`, `tenant` — which exist so that TRDs running in
parallel do not collide on a single export file. They are an internal detail; consumers import the
one entrypoint above.

## The three deployment modes, ranked

`AoidDeploymentMode` has exactly three values. The ranking below is 50-CONTEXT.md's decision **D4**,
best first.

| Rank | Mode | Enum | Where the refresh token lives | Web? |
| ---- | ---- | ---- | ----------------------------- | ---- |
| 1 | **Mode A — BFF / confidential client** | `bff` | **Your backend.** Never reaches the browser. | yes — the default for web |
| 2 | Access token in memory, refresh via a same-site cookie to a BFF | `bff` | Your backend | yes |
| 3 | **Mode B — public client + PKCE** | `publicPkce` | The OS keychain | **no — refused** |
| 4 | **A refresh token in web `localStorage`** | — | **FORBIDDEN** | never |

`sameOrigin` (Mode C) is the third enum value: AOID and the app share an origin, so the session is a
cookie the browser manages and no token reaches Dart at all.

**Rank 4 is not a hypothetical.** A refresh token in web `localStorage` is what this package
**shipped until objective 50**. It was durably readable by any XSS on the eden-biz console, and it
reached storage by four separate write paths — one of which nobody knew about until it was audited.
TRD 50-02 removed the *capability*, not just the call: on web, `AoidMemoryTokenStore` throws on a
non-null refresh write, `AoidSecureTokenStore` refuses to construct, the `shared_preferences`
fallback rethrows for the refresh key, and the legacy-value migration is skipped. Mode B on web is
**unconstructible**, not merely discouraged.

That history is recorded here deliberately. A storage rule with no history reads as caution and gets
traded away the first time someone hits a storage failure on web.

> On web, `flutter_secure_storage` **is** `localStorage` — it puts the AES key and the ciphertext
> there side by side. "Use secure storage instead" is not a fix.

**Mode A's cookie attributes are the consuming app's responsibility.** The SDK cannot enforce
`HttpOnly`, `SameSite` or `Secure`; your backend sets them. `HttpBffCodeSink` checks that at least
one cookie in the response carries both `HttpOnly` and `SameSite` and refuses the exchange
otherwise — but that check **cannot fire on web**, because an httpOnly cookie is invisible to
script by definition. It is a development-time and native-time check, not a guarantee.

Mode A's seam is `AoidCodeSink` — the one method (`submit`) that hands the authorization code and
the PKCE verifier to *your* backend and gets a session back. `HttpBffCodeSink` is the supplied
implementation; implement the interface yourself if your backend's shape differs. Its wire contract
(`POST` to your backend, `application/x-www-form-urlencoded`, fields `code` and `code_verifier`,
success is any 2xx and the body is not read) is specified in full in
`lib/src/aoid/mode/aoid_code_sink.dart` and `http_bff_code_sink.dart`.

> **An `AoidCodeSink` MUST NOT auto-retry `submit`.** An authorization code is single-use, and a
> retry re-presents one that may already have been spent successfully. Failures surface as
> `AoidBffExchangeError`, never `AoidError`: a broken app backend is not a rejected credential, and
> collapsing the two makes every outage look to users like a wrong password.

## The sealed credential widgets

`AoidLoginForm` (password) and `AoidMfaForm` (second factor) own their own text controllers and post
the credential **directly to the AOID issuer over TLS**. The plaintext never enters app-owned Dart.

**The containment mechanism is the ABSENCE of API**, not a runtime guard. There is no per-keystroke
callback, no value-bearing submit callback, no caller-supplied `TextEditingController` or
`FocusNode`, no input formatters, no builder, and no public `State` — a widget cannot leak a value it
never hands out. The `State` classes are private specifically because a public one can be named by an
app-declared `GlobalKey`, whose `.currentState` reaches every private member on it, including the
controller holding the password.

The whole constructor surface is `{key, controller, theme}`. `controller` is an `AoidNativeFlow`,
which exposes step / next / availableMethods / outcome and never the credential. `AoidLoginTheme` is
**input-only** and carries no function-typed field, so it cannot become a side channel either.

> **Do not add a "convenience" API letting an app supply its own password field.** It defeats the
> containment guarantee entirely. `test/aoid/widgets/sealed_form_no_leak_test.dart` is a *source-level*
> gate, because the property is the absence of a member and no runtime assertion can observe one.

## `EdenFeatureGate` is UI hinting ONLY

`lib/src/entitlements/feature_gate.dart` decides whether to **draw** something. It is never an
enforcement point, and the server always re-verifies.

It runs in the client, on state the client holds. Anyone can flip it in devtools. Hiding a button is
a courtesy to the user, not a control on the action behind it — **every capability it hides must be
independently re-checked by whatever server performs the action.**

Do not describe it as a permission check, even loosely, and do not add an `EdenFeatureGate`-shaped
guard to a code path that mutates anything. If you find yourself reaching for one to protect an
operation rather than to tidy a screen, the check belongs on the server.

## Two unrelated entitlement axes that share a word

This is the second documented source of real confusion in this codebase. They are different systems.

| | AOID `ent` | eden-biz entitlements |
| --- | --- | --- |
| Means | **identity / role** | **plan / billing** |
| Source | `identity_memberships(identity_id, tenant_id, client_id).entitlements` | `/api/v1/entitlements/bootstrap` |
| Arrives as | the `ent` claim on the AOID access token | an HTTP response from eden-biz |
| Dart | `AoidAccessClaims.entitlements` | `lib/src/entitlements/entitlements_repository.dart` |
| Answers | "who is this person, in this tenant, for this client" | "what has this account paid for" |

They are **unrelated**. A paid plan grants no identity role; an identity role implies no
subscription. **Do not conflate them** — do not read one where the other belongs, and do not build a
single "entitlements" abstraction over both. They share a word and nothing else.

## The RBAC boundary — AOID owns authN, your app owns authZ

AOID answers *who this is* and *what they are a member of*. Your application answers *what they may
do*. The chain:

```
identity_memberships(identity_id, tenant_id, client_id).entitlements
   -> `ent` claim on the access token
   -> (a) AOEdge injects X-Aoedge-Identity-Context (ctx_ver 2), or
      (b) the app verifies the access token directly against AOID JWKS
   -> the app maps ent[] onto its own roles/permissions
```

**Do not move authZ into AOID.** The moment AOID answers "may this user do X", it accretes the
permission model of every application that asks, and each one's rules become a deployment
dependency of the identity provider.

Reference implementation of the last hop, server-side:
`eden-biz/go/internal/aoidverify/direct_verifier.go` and `internal/middleware/attested.go`.

> **The client cannot verify an AOID token.** JWKS fetch, algorithm pinning and clock-skew tolerance
> all belong on a server. The two Dart decoders — `AoidAccessClaims.decodeUnverified` and
> `AoidIdClaims.decodeUnverified` — are named for exactly that reason: they read claims for UI
> purposes and prove nothing. Never make a trust decision on their output.

## The `tnt` trap

AOID emits a claim named `tnt` on **both** tokens, with different types and different meanings.

| Token | `tnt` is | Changes on a tenant switch? | Dart type | Read it from |
| --- | --- | --- | --- | --- |
| **access token** | the **ACTIVE** tenant's **SLUG** (e.g. `acme`) | **yes** — it follows the switch | `AoidActiveTenantSlug` | `AoidAccessClaims.activeTenant` |
| **id_token** | the **HOME** tenant's **UUID** | no — stable across switches | `AoidHomeTenantId` | `AoidIdClaims.homeTenant` |

When nothing is selected, the access token's `tnt` equals the home tenant's **slug** — so the two
values still differ in *type*, and code that compares them as strings is wrong even in the simple
case.

Both are `extension type`s over `String`, and they **deliberately share no supertype, no accessor
and no conversion** — not even `Object`. Writing one where the other belongs is a *compile error*,
not a runtime surprise. There is no neutral `.value` getter on either: you must write `.slug` or
`.uuid`, which names the mistake at the call site. `test/aoid/claims/no_conflation_compile_gate_test.dart`
runs the analyzer over a probe fixture and asserts the diagnostics, so the property is measured
rather than assumed.

Use `AoidHomeTenantId` to link an AOID identity to a local user record. Using the active-tenant slug
there re-links the user on every switch.

> **Why this trap exists:** AOID's own `internal/oauth/tokens.go` contradicted itself — the
> struct-level comment claimed `tnt` was a UUID while the field comment eight lines below correctly
> said SLUG. TRD 50-07 corrected it. The types above mean a reader who trusted the stale comment
> still cannot ship the mistake.

## Redirect URI registration, per (app, platform)

**AOID compares redirect URIs by EXACT STRING** (`aoid/internal/oauth/service.go:457`). Not a prefix,
not a normalised URL. An invented trailing slash, or a different case, is a rejected authorize
request with no useful error.

The registered values, read from `aoid/config/oauth-clients.yaml`:

| `client_id` (the literal value) | App | Platform | Registered redirect URI | `callbackScheme` |
| --- | --- | --- | --- | --- |
| `eden-biz` | Eden Biz | web (backend RP) | `https://api.biz.aocyber.ai/auth/oidc/callback` | n/a — confidential |
| `eden-biz-companion` | Eden Biz Companion | mobile | `edenbiz://auth` | `edenbiz` |
| `pY28TzI1IUO8WOkD5o8jPQ` | AODex | mobile | `aodex://auth-callback` | `aodex` |
| `pY28TzI1IUO8WOkD5o8jPQ` | AODex | web | `https://dex.aocyber.ai/auth.html` | `https` |

> **AODex's `client_id` is `pY28TzI1IUO8WOkD5o8jPQ`, not `aodex`.** The opaque value is the
> registered one; `AODex` is only the `client_name`, and `aodex-pilot` (aodex/go's `envDefault`) is
> deliberately *not* it either. `aodex` is the URL **scheme**, which is a different field. Sending
> `client_id=aodex` to the authorize endpoint fails. AODex is also a **confidential** client
> (`client_secret_basic`) — its Go BFF holds the secret — so the mobile leg is Mode A, not Mode B.

None of the four registered URIs has a trailing slash. Verified against `aoid/config/oauth-clients.yaml`
by TRD 50-14; `test/aoid/readme_claims_gate_test.dart` asserts the slashed variants never appear here.

Where the scheme is registered on the device:

| Platform | Registration |
| --- | --- |
| iOS / macOS | `Info.plist` -> `CFBundleURLTypes` / `CFBundleURLSchemes` |
| Android | a `flutter_web_auth_2` `CallbackActivity` intent-filter |
| Web | `${origin}/auth.html` — a **static page**, not a Flutter route |

`AoidRedirectOptions.callbackScheme` is **required and has no default**. A shared library cannot
guess a per-app bundle identifier, and this package previously shipped a hardcoded personal one to
every consumer.

> **Web must be a static `auth.html`, not a Flutter route.** Both `aoid/portal` and `aodex/flutter`
> use the default hash URL strategy, so a fragment never reaches the server and a Flutter-routed
> callback cannot receive the code.

## Web caveats

**The authorization code transits `localStorage` for about one second, by construction.**
`url_launcher_web` opens the popup with `noopener,noreferrer`, which nulls `window.opener`, so
`flutter_web_auth_2`'s `postMessage` paths can never fire and its `localStorage` polling path is the
only one that runs. A PKCE-bound, single-use, 60-second authorization code sitting there briefly is
accepted.

**A token would not be. Nobody may add token parameters to `auth.html`.** That page passes a `code`
and nothing else. The repo-wide gate `test/aoid/no_tokens_in_callback_gate_test.dart` scans all of
`lib/` and fails on any code that reads a token out of a URL or builds a URL containing one.

**A blocked popup cannot be detected.** There is no API for it. `AoidRedirectFlow` arms a 20-second
watchdog before launching and, if nothing has come back, emits `AoidRedirectBlockedHint` carrying a
same-tab fallback URL and deliberately hedged copy — *"your browser **may** have blocked the sign-in
window"*. The watchdog is **advice, not detection**: it leaves the future pending, so a slow but
live ceremony still completes and wins. The package's own 300-second timeout is deliberately not
shortened.

**Only the `code_verifier` is stashed**, under one `sessionStorage` key, and only to survive a
full-page same-tab redirect. Not the code, not the state, not a nonce. PKCE carries CSRF on that
path.

## Known limitations

**SDK-07 — tenant switching works, but there is no tenant *list*.** AOID has no authenticated
"list my tenants" RPC: `ResolveWorkspacesByEmail` is pre-login and deliberately enumeration-safe,
`ListTenants` is an admin surface, and `ResolveMembership` resolves exactly one. So this SDK can
**perform** a switch but cannot **populate a picker**. The host application supplies the list. A
stale entry produces a deny-by-default `invalid_grant`, surfaced as `AoidTenantDenied` with a
generic message — the client is not permitted to say *why*, because doing so would build a
membership oracle. That is correct behaviour and a poor user experience, and the two cannot
currently be separated.

**Two different retry postures ship in this SDK. This is a real seam, not an oversight.**

riverpod 3 retries a failed provider *by default* — 10 attempts over ~38 seconds, declining only
`ProviderException` and `Error`. Every ordinary `Exception` is retried, and each retry re-enters
`AsyncLoading`, so `AsyncValue.when()`'s `error:` arm is unreachable for the whole window.

| Surface | Posture | Consequence |
| --- | --- | --- |
| `AoidRedirectFlow.start()` (50-12) | **Returns a sealed `AoidRedirectOutcome` for every expected outcome and never throws.** | riverpod's retry is *structurally* unreachable — there is no error to retry. Safe to wrap in a provider with no ceremony. |
| `AoidTenantController.switchTo()` (50-13) | **Throws `AoidTenantDenied`**, defended by the explicit `aoidTenantSwitchRetry` policy. | Safe only where that policy is wired. `AoidTenantController` is a plain `ChangeNotifier`, so the default path never enters retry machinery — but a consumer that *does* wrap the switch in a provider **must** pass `retry: aoidTenantSwitchRetry`. |

The sealed-return form is the stronger of the two: it defends every consumer, including ones not
yet written, whereas an opt-out policy defends only the call sites someone remembers to wire. 50-13
declined to adopt it **deliberately** — its contract mandated the throw in three places whose gates
were already proven, and reworking the surface afterwards would have traded a measured result for
an unmeasured one. A sealed `AoidTenantSwitchResult` returning `AoidTenantDenied` as a *value* is a
recorded follow-up, and it is an API change with consumers rather than a tidy-up.

**Nothing in this module has been exercised against a live AOID.** Every contract here is proven
against hand-built fakes modelled on AOID's Go source, with non-vacuity controls. Specifically:
Modes A and C are proven only through **injected closures**; the Mode A wire contract has never
been sent to a real backend; the tenant-denial and membership-gate behaviour is modelled from
`internal/oauth/service.go`, not observed; and the `tnt` divergence is pinned against fixtures
encoding documented server behaviour rather than a captured production token. First real
integration is the first real proof.

**The AODex web redirect leg is registered but not yet serviceable.** `https://dex.aocyber.ai/auth.html`
is registered on the `aodex` client, but `aodex/flutter/web/auth.html` **does not exist yet** —
`oauth-clients.yaml` says so in its own comment. The web leg cannot be smoke-tested until it lands.

**`CompanySwitcher` is not a universal entry point.** eden-biz's integration test imports
`eden_platform.dart` with `hide CompanySwitcher`. Drive `AoidTenantController` directly if you need
the switch without that widget.

**`AoidOidcAuthStrategy.restoreSession` still collapses every non-200 to `null`**, so a 500 or a
network blip signs the user out rather than surfacing as a transient failure. The types needed to
fix it exist (`AoidTransportError`, `AoidBffExchangeError`); the three-way outcome is not yet wired.

## Where things live

| Concern | Path |
| --- | --- |
| Claims + the two tenant types | `lib/src/aoid/claims/` |
| Deployment modes, the Mode A sink | `lib/src/aoid/mode/` |
| Token stores (D4 custody) | `lib/src/aoid/storage/` |
| Native password/MFA ceremony | `lib/src/aoid/transport/`, `lib/src/aoid/flow/` |
| Browser hop (redirect) | `lib/src/aoid/flow/aoid_redirect_*.dart` |
| Sealed credential widgets | `lib/src/aoid/widgets/` |
| Tenant switching | `lib/src/aoid/tenant/` |
| A minimal Mode A integration | `example/aoid_quickstart/main.dart` |

The claims in this document are gated by `test/aoid/readme_claims_gate_test.dart`. If you reword a
section and that test fails, restore the substance rather than weakening the predicate.
