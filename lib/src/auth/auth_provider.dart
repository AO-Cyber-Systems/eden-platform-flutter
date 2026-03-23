import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/platform_repository.dart';
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

final platformRepositoryProvider = Provider<PlatformRepository>((ref) {
  return ConnectPlatformRepository(
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:8080',
    ),
  );
});

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({required PlatformRepository repository})
      : _repository = repository,
        super(const AuthState.unknown()) {
    unawaited(restoreSession());
  }

  final PlatformRepository _repository;

  Future<void> login(String email, String password) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.login(email, password);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } catch (error) {
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  Future<void> signUp(String email, String password, String displayName) async {
    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.signUp(email, password, displayName);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } catch (error) {
      state = AuthState.error(error.toString(), session: state.session);
    }
  }

  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('refresh_token');
    if (refreshToken == null || refreshToken.isEmpty) {
      state = const AuthState.unauthenticated();
      return;
    }

    state = AuthState.refreshing(session: state.session);
    try {
      final session = await _repository.refreshToken(refreshToken);
      await _persistTokens(session);
      state = AuthState.authenticated(session);
    } catch (_) {
      await _clearPersistedTokens();
      state = const AuthState.unauthenticated();
    }
  }

  Future<void> logout() async {
    final refreshToken = state.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _repository.logout(refreshToken);
      } catch (_) {}
    }
    await _clearPersistedTokens();
    state = const AuthState.unauthenticated();
  }

  Future<void> _persistTokens(PlatformSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', session.accessToken);
    await prefs.setString('refresh_token', session.refreshToken);
  }

  Future<void> _clearPersistedTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(repository: ref.watch(platformRepositoryProvider));
});
