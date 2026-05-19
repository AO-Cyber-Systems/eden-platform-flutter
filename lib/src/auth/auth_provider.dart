import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/platform_repository.dart';
import 'auth_strategy.dart';
import 'secure_token_storage.dart';
import 'sso_auth_service.dart';
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

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({
    required PlatformRepository repository,
    required TokenStorage tokenStorage,
    AuthStrategy? strategy,
  })  : _repository = repository,
        _tokenStorage = tokenStorage,
        _strategy = strategy,
        super(const AuthState.unknown()) {
    unawaited(restoreSession());
  }

  final PlatformRepository _repository;
  final TokenStorage _tokenStorage;
  final AuthStrategy? _strategy;

  /// Last continuation token returned by [_strategy] for a multi-step
  /// login. Held in memory only — the UI passes it back via
  /// [completeLogin] when submitting the second factor.
  String? _continuationToken;

  /// Last continuation token surfaced from a multi-step login. Consumers
  /// that need to render an MFA prompt can read this to scope the prompt
  /// to the in-flight login attempt.
  String? get continuationToken => _continuationToken;

  /// Whether this notifier is delegating to a custom [AuthStrategy]. When
  /// false, the notifier executes the legacy email+password flow against
  /// [PlatformRepository].
  bool get usesStrategy => _strategy != null;

  Future<void> login(String email, String password) async {
    state = AuthState.refreshing(session: state.session);
    if (_strategy != null) {
      try {
        final result = await _strategy.initiateLogin({
          'email': email,
          'password': password,
        });
        _applyAuthResult(result);
      } catch (error) {
        state = AuthState.error(error.toString(), session: state.session);
      }
      return;
    }
    try {
      final session = await _repository.login(email, password);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
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
      _applyAuthResult(result);
    } catch (error) {
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
      _applyAuthResult(result);
    } catch (error) {
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  /// Reduce an [AuthResult] from a strategy into the [AuthState] machine.
  void _applyAuthResult(AuthResult result) {
    switch (result) {
      case Authenticated(:final session):
        _continuationToken = null;
        // Only persist tokens for bearer-style sessions; cookie-bound
        // sessions have empty token strings that would clobber any prior
        // real values in secure storage.
        if (!session.cookieBound) {
          unawaited(_persistTokens(session));
        }
        state = AuthState.authenticated(session);
      case TwoFactorRequired(:final continuationToken):
        _continuationToken = continuationToken;
        // Refreshing state semantically covers "waiting for the user to
        // provide a second factor" — downstream UI inspects
        // [continuationToken] to disambiguate.
        state = AuthState.refreshing(session: state.session);
      case Failed(:final reason):
        _continuationToken = null;
        state = AuthState.error(reason, session: state.session);
    }
  }

  Future<void> signUp(String email, String password, String displayName) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.signUp(email, password, displayName);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  Future<void> restoreSession() async {
    // Strategy path: defer entirely to the injected strategy. Cookie-bound
    // flows have no refresh-token to read, so we skip the secure-storage
    // probe.
    if (_strategy != null) {
      if (state.isAuthenticated) return;
      state = AuthState.refreshing(session: state.session);
      try {
        final session = await _strategy.restoreSession();
        if (session != null) {
          state = AuthState.authenticated(session);
        } else {
          state = const AuthState.unauthenticated();
        }
      } catch (e) {
        log('Strategy restoreSession failed: $e', name: 'AuthNotifier');
        state = const AuthState.unauthenticated();
      }
      return;
    }

    final refreshToken = await _tokenStorage.readRefreshToken();
    // Re-check after async gap — state may have been set externally (dev injection).
    if (state.isAuthenticated) return;
    if (refreshToken == null || refreshToken.isEmpty) {
      state = const AuthState.unauthenticated();
      return;
    }

    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.refreshToken(refreshToken);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } on AuthError {
      await _clearPersistedTokens();
      state = const AuthState.unauthenticated();
    } on NetworkError catch (e) {
      log('Session restore failed (network): $e', name: 'AuthNotifier');
      state = AuthState.error(
        'Network unavailable. Please check your connection.',
        session: state.session,
      );
    } catch (e) {
      log('Session restore failed: $e', name: 'AuthNotifier');
      await _clearPersistedTokens();
      state = const AuthState.unauthenticated();
    }
  }

  /// Login via SSO provider (Microsoft, Google).
  /// Desktop: opens browser, captures callback. Web: redirects window.
  Future<void> loginWithSSO(String provider, {String? redirectUri}) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final ssoService = SSOAuthService(
        repository: _repository,
        apiBaseUrl: _resolvePlatformBaseUrl(),
      );
      final session = await ssoService.authenticate(provider);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } on PlatformError catch (error) {
      state = AuthState.error(error.message, session: state.session);
    } catch (error) {
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  Future<void> updateProfile(String displayName, String avatarUrl) async {
    final token = state.accessToken;
    if (token == null) return;
    try {
      final updatedUser = await _repository.updateProfile(token, displayName, avatarUrl);
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
    if (_strategy != null) {
      try {
        await _strategy.logout();
      } catch (e) {
        log('Strategy logout failed (non-blocking): $e', name: 'AuthNotifier');
      }
      _continuationToken = null;
      // Best-effort: clear any stale tokens that might still be persisted
      // from a pre-strategy boot.
      await _clearPersistedTokens();
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
    state = const AuthState.unauthenticated();
  }

  Future<void> _persistTokens(PlatformSession session) async {
    await _tokenStorage.writeAccessToken(session.accessToken);
    await _tokenStorage.writeRefreshToken(session.refreshToken);
  }

  Future<void> _clearPersistedTokens() async {
    await _tokenStorage.clear();
  }
}

/// Optional override hook for consumers that want to inject a custom
/// [AuthStrategy] (e.g., AOID's multi-step PasswordLoginStart/Complete
/// flow). Default: null, which preserves the legacy email+password flow
/// against [PlatformRepository].
final authStrategyProvider = Provider<AuthStrategy?>((ref) => null);

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    repository: ref.watch(platformRepositoryProvider),
    tokenStorage: ref.watch(tokenStorageProvider),
    strategy: ref.watch(authStrategyProvider),
  );
});
