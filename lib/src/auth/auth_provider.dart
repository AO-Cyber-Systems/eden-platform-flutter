import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/platform_repository.dart';
import 'auth_strategy.dart';
import 'secure_token_storage.dart';
import 'social_auth_service.dart';
import 'token_storage.dart';
import '../errors/platform_errors.dart';
import '../models/platform_models.dart';

enum AuthStatus { unknown, refreshing, authenticated, unauthenticated, error }

class AuthState {
  final AuthStatus status;
  final PlatformSession? session;
  final String? errorMessage;

  const AuthState({
    required this.status,
    this.session,
    this.errorMessage,
  });

  const AuthState.unknown() : this(status: AuthStatus.unknown);
  const AuthState.refreshing({PlatformSession? session})
      : this(status: AuthStatus.refreshing, session: session);
  const AuthState.authenticated(PlatformSession session)
      : this(status: AuthStatus.authenticated, session: session);
  const AuthState.unauthenticated()
      : this(status: AuthStatus.unauthenticated);
  const AuthState.error(String message, {PlatformSession? session})
      : this(status: AuthStatus.error, errorMessage: message, session: session);

  bool get isAuthenticated => status == AuthStatus.authenticated && session != null;
  String? get accessToken => session?.accessToken;

  /// The AOID OIDC id_token for the active session, or null when there is no
  /// session or the session carries no id_token (password/cookie sessions,
  /// or an AOID response that omitted it). Surfaced so the biz transport can
  /// attach it as the `X-AOID-ID-Token` header (COMPANION-AV05-AOID-JIT).
  String? get idToken => session?.idToken;
  String? get refreshToken => session?.refreshToken;
  String? get userId => session?.user.id;
  String? get companyId => session?.companyId;
  String? get role => session?.role;
  PlatformUser? get user => session?.user;
}

/// Resolves the platform API base URL at runtime.
/// Uses API_BASE_URL if set at compile time, otherwise derives from browser location.
String _resolvePlatformBaseUrl() {
  const envUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  if (envUrl.isNotEmpty) return envUrl;
  try {
    final uri = Uri.base;
    return '${uri.scheme}://${uri.host}:${uri.port}';
  } catch (_) {
    return 'http://localhost:8080';
  }
}

final platformRepositoryProvider = Provider<PlatformRepository>((ref) {
  return ConnectPlatformRepository(
    baseUrl: _resolvePlatformBaseUrl(),
  );
});

/// Provider for the token persistence backend.
///
/// Default: [SecureTokenStorage] using `flutter_secure_storage` 9.2.4
/// (Keychain on iOS, EncryptedSharedPreferences on Android) with transparent
/// migration from `shared_preferences` for upgraded installs.
///
/// Tests override with a fake [TokenStorage]. Apps may override for custom
/// persistence (e.g. encrypted-at-rest with app-managed keys).
final tokenStorageProvider = Provider<TokenStorage>((ref) {
  return SecureTokenStorage();
});

class AuthNotifier extends Notifier<AuthState> {
  // riverpod 3 `Notifier` subclasses must have a zero-argument constructor —
  // there is no constructor injection. The three dependencies that used to be
  // constructor parameters are resolved in [build] instead. They are `late`
  // rather than nullable so that a method reached before [build] fails loudly
  // with a LateInitializationError instead of silently behaving as though no
  // strategy/repository were configured.
  late PlatformRepository _repository;
  late TokenStorage _tokenStorage;
  late AuthStrategy? _strategy;

  @override
  AuthState build() {
    _repository = ref.watch(platformRepositoryProvider);
    _tokenStorage = ref.watch(tokenStorageProvider);
    _strategy = ref.watch(authStrategyProvider);

    // A `Notifier` instance is REUSED across a rebuild. riverpod 3.3.2's own
    // dartdoc on `Notifier.build` (providers/notifier/orphan.dart:57-60) is
    // explicit: "If a dependency of this Notifier (when using Ref.watch)
    // changes, then build will be re-executed. On the other hand, the Notifier
    // will not be recreated. Its instance will be preserved between executions
    // of build."
    //
    // The `StateNotifierProvider` this replaced did the opposite: its create
    // callback ran `AuthNotifier(...)` afresh on every rebuild, so every field
    // outside `state` was discarded. MEASURED on the pre-migration code, a
    // continuation token captured before `container.invalidate(authProvider)`
    // read back as null afterwards.
    //
    // So these two resets are NOT redundant — they are the only thing that
    // still clears in-flight ceremony state on a rebuild. Both hold a live
    // server-side handle:
    //   * `_continuationToken` is an objective-49 `auth_session` handle, which
    //     The issuer rotates on EVERY step. A handle surviving the rebuild that was
    //     meant to discard it lets a later completeLogin present a token from
    //     an abandoned ceremony.
    //   * `_pendingRedirectUrl` carries an OAuth authorization URL with its
    //     `state` parameter. Its own doc below promises a stale hop "can never
    //     be opened after the ceremony has moved on"; a rebuild is exactly such
    //     a move.
    // Pinned by test: "a rebuild clears the in-flight ceremony state".
    _continuationToken = null;
    _pendingRedirectUrl = null;

    // The boot-time session restore. This was a CONSTRUCTOR side effect under
    // `StateNotifier` (`super(const AuthState.unknown())` ran first, so `state`
    // was already readable by the time the constructor body called it).
    //
    // It is deferred by a microtask here because `restoreSession` reads `state`
    // synchronously on the strategy path (`if (state.isAuthenticated) return;`)
    // and `state` does not exist until `build` RETURNS. Calling it directly
    // throws StateError: "Tried to read the state of an uninitialized provider".
    //
    // The observable cadence is unchanged: once per build, exactly as the old
    // StateNotifierProvider — which also rebuilt the notifier whenever any of
    // the same three watched providers changed. Pinned by test rather than
    // argued: "restoreSession runs exactly once per provider build".
    unawaited(Future.microtask(restoreSession));

    return const AuthState.unknown();
  }

  /// Restores riverpod 2's notify-on-every-assignment behaviour.
  ///
  /// riverpod 3.0.0, breaking change: *"All providers now use `==` to compare
  /// previous/new values and filter updates. If you want to revert to the old
  /// behavior, you can override `updateShouldNotify` inside Notifiers."*
  ///
  /// [AuthState] declares no `operator ==`, so `==` degrades to identity — and
  /// every terminal sentinel here is built by a **const** named constructor
  /// (`AuthState.unauthenticated()`, `AuthState.unknown()`). Dart canonicalizes
  /// const instances, so `state = const AuthState.unauthenticated()` assigned
  /// while already unauthenticated is *the identical object*, and the default
  /// filter drops it.
  ///
  /// Three providers clear themselves off that notification —
  /// `company_provider`, `nav_provider` and `entitlements_provider` all listen
  /// to this provider and call their own `clear()` when `next.isAuthenticated`
  /// is false. A dropped sign-out signal leaves the previous tenant's
  /// companies, navigation and entitlements resident, which in a multi-tenant
  /// console is a cross-account exposure.
  ///
  /// **This is NOT a riverpod 3 regression.** MEASURED both ways: the legacy
  /// `StateNotifier` suppressed exactly the same assignment, because
  /// `StateNotifier.updateShouldNotify` defaults to `!identical(old, current)`
  /// (state_notifier 1.0.0, state_notifier.dart:203-207) and for a class with
  /// no value `==` that is the same predicate. The defect predates the version
  /// bump; the migration is merely where it was found. See
  /// doc/riverpod-3-migration.md §3.8.
  ///
  /// Deliberately scoped to this notifier. Giving [AuthState] an `operator ==`
  /// would change equality semantics for every consumer in 18 packages, which
  /// is a far larger decision than restoring one notification.
  @override
  bool updateShouldNotify(AuthState previous, AuthState next) => true;

  /// Last continuation token returned by [_strategy] for a multi-step
  /// login. Held in memory only — the UI passes it back via
  /// [completeLogin] when submitting the second factor.
  String? _continuationToken;

  /// Last continuation token surfaced from a multi-step login. Consumers
  /// that need to render an MFA prompt can read this to scope the prompt
  /// to the in-flight login attempt.
  String? get continuationToken => _continuationToken;

  /// Authorization URL surfaced by the most recent [RedirectRequired], or
  /// null when no browser hop is pending.
  ///
  /// A redirect is a FIRST-CLASS path, not an error: the
  /// notifier stays in [AuthStatus.refreshing] and exposes the URL here so
  /// the UI can open a system browser (ASWebAuthenticationSession / Chrome
  /// Custom Tabs) and finish via the redirect flow. It is surfaced as a
  /// notifier field rather than a new [AuthStatus] value deliberately —
  /// adding an enum value breaks every exhaustive switch in the 18 packages
  /// that consume [AuthState].
  ///
  /// Cleared by any subsequent result, so a stale URL can never be opened
  /// after the ceremony has moved on.
  Uri? _pendingRedirectUrl;
  Uri? get pendingRedirectUrl => _pendingRedirectUrl;

  /// Whether this notifier is delegating to a custom [AuthStrategy]. When
  /// false, the notifier executes the legacy email+password flow against
  /// [PlatformRepository].
  bool get usesStrategy => _strategy != null;

  Future<void> login(String email, String password) async {
    // Read into a local: `_strategy` is a `late` field now, and Dart does not
    // type-promote non-final fields, so `_strategy.initiateLogin` after a null
    // check would not compile. Same reason `initiateStrategyLogin` and
    // `completeLogin` already did this.
    final strategy = _strategy;
    state = AuthState.refreshing(session: state.session);
    if (strategy != null) {
      try {
        final result = await strategy.initiateLogin({
          'email': email,
          'password': password,
        });
        if (!ref.mounted) return;
        _applyAuthResult(result);
      } catch (error) {
        if (!ref.mounted) return;
        state = AuthState.error(error.toString(), session: state.session);
      }
      return;
    }
    try {
      final session = await _repository.login(email, password);
      await _persistTokens(session);
      if (!ref.mounted) return;
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  /// Initiate a login using the injected [AuthStrategy] with arbitrary
  /// [credentials]. Throws [StateError] when no strategy is configured.
  /// Tests and consumers that need richer credentials than email+password
  /// should call this directly rather than [login].
  Future<void> initiateStrategyLogin(Map<String, String> credentials) async {
    final strategy = _strategy;
    if (strategy == null) {
      throw StateError('AuthNotifier has no AuthStrategy configured');
    }
    state = AuthState.refreshing(session: state.session);
    try {
      final result = await strategy.initiateLogin(credentials);
      if (!ref.mounted) return;
      _applyAuthResult(result);
    } catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  /// Complete a multi-step login by submitting [proof] (e.g. TOTP code).
  /// Uses the continuation token captured from the most recent
  /// [TwoFactorRequired]. Throws [StateError] when no continuation is
  /// pending.
  Future<void> completeLogin(Map<String, String> proof) async {
    final strategy = _strategy;
    final token = _continuationToken;
    if (strategy == null) {
      throw StateError('AuthNotifier has no AuthStrategy configured');
    }
    if (token == null) {
      throw StateError(
        'No continuation token pending — call initiateStrategyLogin first',
      );
    }
    state = AuthState.refreshing(session: state.session);
    try {
      final result = await strategy.completeLogin(token, proof);
      if (!ref.mounted) return;
      _applyAuthResult(result);
    } catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  /// Reduce an [AuthResult] from a strategy into the [AuthState] machine.
  void _applyAuthResult(AuthResult result) {
    switch (result) {
      case Authenticated(:final session):
        _continuationToken = null;
        _pendingRedirectUrl = null;
        // Only persist tokens for bearer-style sessions; cookie-bound
        // sessions have empty token strings that would clobber any prior
        // real values in secure storage.
        if (!session.cookieBound) {
          unawaited(_persistTokens(session));
        }
        state = AuthState.authenticated(session);
      case FactorRequired(:final continuationToken):
        // The issuer rotates `auth_session` on EVERY step. This
        // write is the rotation capture: the handle we just received replaces
        // the one we presented. Removing it makes the second completeLogin
        // present a consumed handle and fail with invalid_session. Pinned by
        // test/auth_provider_test.dart "rotation across sequential
        // completeLogin".
        _continuationToken = continuationToken;
        _pendingRedirectUrl = null;
        // Refreshing state semantically covers "waiting for the user to
        // provide a second factor" — downstream UI inspects
        // [continuationToken] to disambiguate.
        state = AuthState.refreshing(session: state.session);
      // NOTE: there is deliberately no `case TwoFactorRequired`. It is a
      // SUBCLASS of FactorRequired (auth_strategy.dart), so the arm above
      // already matches it — including the AOID portal's deprecated
      // `const TwoFactorRequired(...)` construction. A separate arm here
      // would be dead code.
      case RedirectRequired(:final authorizationUrl):
        // NOT an error. The user merely needs a browser
        // hop — social IdP, PIV/CAC, or a tenancy tier that forbids native
        // login. Mapping this onto AuthState.error is the exact defect this
        // contract exists to remove: it shows "login failed" to a user whose
        // credentials are fine. Pinned by test/auth_provider_test.dart
        // "RedirectRequired does not put the notifier into an error state".
        _pendingRedirectUrl = authorizationUrl;
        state = AuthState.refreshing(session: state.session);
      case Failed(:final reason):
        _continuationToken = null;
        _pendingRedirectUrl = null;
        state = AuthState.error(reason, session: state.session);
    }
  }

  Future<void> signUp(String email, String password, String displayName) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.signUp(email, password, displayName);
      await _persistTokens(session);
      if (!ref.mounted) return;
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  Future<void> restoreSession() async {
    // Strategy path: defer entirely to the injected strategy. Cookie-bound
    // flows have no refresh-token to read, so we skip the secure-storage
    // probe.
    final strategy = _strategy;
    if (strategy != null) {
      if (state.isAuthenticated) return;
      state = AuthState.refreshing(session: state.session);
      try {
        final session = await strategy.restoreSession();
        if (!ref.mounted) return;
        if (session != null) {
          state = AuthState.authenticated(session);
        } else {
          state = const AuthState.unauthenticated();
        }
      } catch (e) {
        log('Strategy restoreSession failed: $e', name: 'AuthNotifier');
        if (!ref.mounted) return;
        state = const AuthState.unauthenticated();
      }
      return;
    }

    String? refreshToken;
    try {
      refreshToken = await _tokenStorage.readRefreshToken();
    } catch (e) {
      // Reading secure storage can throw (e.g. on web, where
      // flutter_secure_storage may have no implementation or Web Crypto
      // rejects a stale ciphertext). An unhandled throw here leaves auth stuck
      // in `unknown` forever, hanging every gated route behind a spinner — so
      // swallow it, clear any persisted tokens, and fall through to login.
      log('Token storage read failed during session restore: $e', name: 'AuthNotifier');
      await _clearPersistedTokensBestEffort();
      if (!ref.mounted) return;
      state = const AuthState.unauthenticated();
      return;
    }
    // Re-check after async gap — state may have been set externally (dev
    // injection). Reading `state` after disposal throws in riverpod 3 where
    // riverpod 2 tolerated it, so the liveness check has to come FIRST.
    if (!ref.mounted) return;
    if (state.isAuthenticated) return;
    if (refreshToken == null || refreshToken.isEmpty) {
      state = const AuthState.unauthenticated();
      return;
    }

    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.refreshToken(refreshToken);
      await _persistTokens(session);
      if (!ref.mounted) return;
      state = AuthState.authenticated(session);
    } on AuthError {
      await _clearPersistedTokensBestEffort();
      if (!ref.mounted) return;
      state = const AuthState.unauthenticated();
    } on NetworkError catch (e) {
      log('Session restore failed (network): $e', name: 'AuthNotifier');
      if (!ref.mounted) return;
      state = AuthState.error(
        'Network unavailable. Please check your connection.',
        session: state.session,
      );
    } catch (e) {
      log('Session restore failed: $e', name: 'AuthNotifier');
      await _clearPersistedTokensBestEffort();
      if (!ref.mounted) return;
      state = const AuthState.unauthenticated();
    }
  }

  // REMOVED: `loginWithSSO`.
  //
  // It was the sole caller of `SSOAuthService`, which read `access_token` and
  // `refresh_token` straight out of a desktop loopback callback URL and
  // launched the system browser via `Process.run`. A repo-wide grep across
  // ~/dev (excluding.pub-cache and worktrees) found ZERO callers of either
  // symbol, so the whole chain was deleted rather than repaired.
  //
  // Desktop is already covered by `flutter_web_auth_2`, which [SocialAuthService]
  // uses on every platform. Gate: test/aoid/no_tokens_in_callback_gate_test.dart.

  /// Login via a consumer social provider (Google, Apple, Microsoft,
  /// Facebook, X). Drives [SocialAuthService] (flutter_web_auth_2 → server
  /// callback carrying an authorization CODE → POST exchange → token pair in
  /// the response body) and persists via the same SecureTokenStorage path as
  /// password login.
  Future<void> loginWithSocial(String provider) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final socialService = SocialAuthService(
        repository: _repository,
        baseUrl: _resolvePlatformBaseUrl(),
        // REQUIRED per-app configuration. Previously a hardcoded
        // personal bundle identifier in the shared library, which meant every
        // consumer's mobile callback claimed to be one developer's app.
        // Build with --dart-define=SOCIAL_CALLBACK_SCHEME=<your.bundle.id>.
        // Throws ArgumentError when unset — caught below and surfaced as an
        // auth error rather than failing silently on a device.
        callbackScheme: SocialAuthService.callbackSchemeFromEnvironment(),
      );
      final session = await socialService.authenticate(provider);
      await _persistTokens(session);
      if (!ref.mounted) return;
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
      if (!ref.mounted) return;
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  /// FIX-19 2026-05-20: drop a fresh (accessToken, refreshToken) pair into
  /// the session without going through the platform RefreshToken RPC.
  ///
  /// Used by biz's company-switch flow: POST /companies/switch on the biz
  /// backend re-mints tokens scoped to the target company; this method
  /// persists them and flips authState so the rest of the app picks up
  /// the new cid claim immediately.
  ///
  /// Preserves the current `user` object (same human, different company)
  /// and pulls the new companyId/role from the optional overrides. Callers
  /// should invalidate company-scoped caches after calling this.
  Future<void> replaceSession({
    required String accessToken,
    required String refreshToken,
    String? companyId,
    String? role,
  }) async {
    final existingUser = state.session?.user;
    if (existingUser == null) {
      // No active session to swap into — fall back to refreshing from
      // storage. Callers should normally only invoke this while authed.
      await restoreSession();
      return;
    }
    final newSession = PlatformSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: existingUser,
      companyId: companyId ?? state.companyId,
      role: role ?? state.role,
    );
    await _persistTokens(newSession);
    if (!ref.mounted) return;
    state = AuthState.authenticated(newSession);
  }

  Future<void> updateProfile(String displayName, String avatarUrl) async {
    final token = state.accessToken;
    if (token == null) return;
    try {
      final updatedUser = await _repository.updateProfile(token, displayName, avatarUrl);
      if (!ref.mounted) return;
      state = AuthState.authenticated(PlatformSession(
        accessToken: state.session!.accessToken,
        refreshToken: state.session!.refreshToken,
        user: updatedUser,
        companyId: state.companyId,
        role: state.role,
      ));
    } catch (e) {
      // Don't change auth state on profile update failure
      rethrow;
    }
  }

  Future<void> logout() async {
    final strategy = _strategy;
    if (strategy != null) {
      try {
        await strategy.logout();
      } catch (e) {
        log('Strategy logout failed (non-blocking): $e', name: 'AuthNotifier');
      }
      _continuationToken = null;
      // Best-effort: clear any stale tokens that might still be persisted
      // from a pre-strategy boot.
      await _clearPersistedTokens();
      if (!ref.mounted) return;
      state = const AuthState.unauthenticated();
      return;
    }
    final refreshToken = state.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _repository.logout(refreshToken);
      } catch (e) {
        log('Logout API call failed (non-blocking): $e', name: 'AuthNotifier');
      }
    }
    await _clearPersistedTokens();
    if (!ref.mounted) return;
    state = const AuthState.unauthenticated();
  }

  /// Rotate the in-memory session tokens after a silent token refresh.
  ///
  /// Called by the app's [TokenStore.setTokens] implementation when the
  /// ConnectRPC auth interceptor completes a reactive token refresh. Updates
  /// the live [AuthState.session] with the new token pair and persists them
  /// to secure storage so the next app restart restores correctly.
  ///
  /// No-op when the current session is null (unauthenticated) — there is
  /// nothing to update in that case and the interceptor will drive logout.
  Future<void> rotateTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final current = state.session;
    if (current == null) return;
    final updated = PlatformSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: current.user,
      companyId: current.companyId,
      role: current.role,
    );
    await _persistTokens(updated);
    if (!ref.mounted) return;
    state = AuthState.authenticated(updated);
  }

  Future<void> _persistTokens(PlatformSession session) async {
    await _tokenStorage.writeAccessToken(session.accessToken);
    await _tokenStorage.writeRefreshToken(session.refreshToken);
  }

  Future<void> _clearPersistedTokens() async {
    await _tokenStorage.clear();
  }

  /// Clears persisted tokens without ever throwing.
  ///
  /// Used only from [restoreSession]'s failure branches, which are already
  /// handling one failure — the cleanup must not raise a second one on top of
  /// it. This matters because the constructor fires
  /// `unawaited(restoreSession())`: there is no caller to catch anything that
  /// escapes, so a throw here becomes an unhandled async zone error and, worse,
  /// skips the `state = unauthenticated` assignment that follows every call
  /// site — leaving the notifier stranded on a stale `authenticated` session or
  /// pinned in `unknown`, which is the exact "gated routes hang behind a
  /// spinner" failure the read-branch comment above set out to prevent.
  ///
  /// The failure is real on web, where `flutter_secure_storage` has no
  /// implementation and [SecureTokenStorage] falls through to
  /// `shared_preferences`, whose `getAll` then throws MissingPluginException.
  ///
  /// Logged rather than reported: the storage failure is a *consequence* of the
  /// restore failure already logged by the caller, and it is not independently
  /// actionable — the user-visible outcome is identical either way (signed
  /// out). Routing it to Sentry from here would add an observability coupling
  /// to a code path that handles raw tokens, and genuinely unexpected errors
  /// still reach the app's zone handler through other routes. `log` keeps it
  /// diagnosable, consistent with the sibling "non-blocking" failures in
  /// [logout].
  ///
  /// Deliberately NOT applied to [logout]'s clear calls: those are awaited by a
  /// caller that can surface the failure, so they keep their throwing
  /// behaviour.
  Future<void> _clearPersistedTokensBestEffort() async {
    try {
      await _clearPersistedTokens();
    } catch (e) {
      // Tokens may survive on disk, but they are already known-unusable
      // (unreadable, or rejected by refresh). Signing out is still the correct
      // and coherent end state; the next restore attempt will retry the clear.
      log('Token storage clear failed during session restore cleanup: $e',
          name: 'AuthNotifier');
    }
  }
}

/// Optional override hook for consumers that want to inject a custom
/// [AuthStrategy] (e.g., AOID's multi-step PasswordLoginStart/Complete
/// flow). Default: null, which preserves the legacy email+password flow
/// against [PlatformRepository].
final authStrategyProvider = Provider<AuthStrategy?>((ref) => null);

// Signature verified against the RESOLVED riverpod 3.3.2 rather than the
// changelog: `NotifierProvider(this._createNotifier, {name, dependencies,
// isAutoDispose = false, retry})` — riverpod-3.3.2/lib/src/providers/notifier/
// orphan.dart:78-94. Keep-alive (no `isAutoDispose`), matching the lifetime the
// StateNotifierProvider had.
//
// The IDENTIFIER `authProvider` and the state type `AuthState` are a contract
// with concurrent work that consumes both by name.
final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
