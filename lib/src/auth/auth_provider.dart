import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class AuthState {
  final String? accessToken;
  final String? refreshToken;
  final String? userId;
  final String? companyId;
  final String? role;
  final bool isAuthenticated;

  const AuthState({
    this.accessToken,
    this.refreshToken,
    this.userId,
    this.companyId,
    this.role,
    this.isAuthenticated = false,
  });

  AuthState copyWith({
    String? accessToken,
    String? refreshToken,
    String? userId,
    String? companyId,
    String? role,
    bool? isAuthenticated,
  }) {
    return AuthState(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      userId: userId ?? this.userId,
      companyId: companyId ?? this.companyId,
      role: role ?? this.role,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final String baseUrl;

  AuthNotifier({required this.baseUrl}) : super(const AuthState());

  Future<void> login(String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/circle.v1.AuthService/Login'),
      headers: {
        'Content-Type': 'application/json',
        'Connect-Protocol-Version': '1',
      },
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (response.statusCode != 200) {
      throw Exception('Login failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', data['accessToken']);
    await prefs.setString('refresh_token', data['refreshToken']);

    state = AuthState(
      accessToken: data['accessToken'],
      refreshToken: data['refreshToken'],
      userId: data['user']?['id'],
      companyId: _extractCompanyId(data['accessToken']),
      role: _extractRole(data['accessToken']),
      isAuthenticated: true,
    );
  }

  Future<void> signUp(
    String email,
    String password,
    String displayName,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/circle.v1.AuthService/SignUp'),
      headers: {
        'Content-Type': 'application/json',
        'Connect-Protocol-Version': '1',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
        'displayName': displayName,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Signup failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', data['accessToken']);
    await prefs.setString('refresh_token', data['refreshToken']);

    state = AuthState(
      accessToken: data['accessToken'],
      refreshToken: data['refreshToken'],
      userId: data['user']?['id'],
      companyId: _extractCompanyId(data['accessToken']),
      role: _extractRole(data['accessToken']),
      isAuthenticated: true,
    );
  }

  Future<void> logout() async {
    if (state.refreshToken != null) {
      try {
        await http.post(
          Uri.parse('$baseUrl/circle.v1.AuthService/Logout'),
          headers: {
            'Content-Type': 'application/json',
            'Connect-Protocol-Version': '1',
          },
          body: jsonEncode({'refreshToken': state.refreshToken}),
        );
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    state = const AuthState();
  }

  Future<void> tryRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString('access_token');
    final refreshToken = prefs.getString('refresh_token');

    if (accessToken != null && refreshToken != null) {
      state = AuthState(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: _extractUserId(accessToken),
        companyId: _extractCompanyId(accessToken),
        role: _extractRole(accessToken),
        isAuthenticated: true,
      );
    }
  }

  /// Inject a fake session for testing (no real JWT needed).
  void injectTestSession({
    required String userId,
    required String companyId,
    required String role,
  }) {
    state = AuthState(
      accessToken: 'test-token',
      refreshToken: 'test-refresh',
      userId: userId,
      companyId: companyId,
      role: role,
      isAuthenticated: true,
    );
  }

  String? _extractCompanyId(String? token) => _extractClaim(token, 'cid');
  String? _extractRole(String? token) => _extractClaim(token, 'role');
  String? _extractUserId(String? token) => _extractClaim(token, 'uid');

  String? _extractClaim(String? token, String key) {
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final map = jsonDecode(payload) as Map<String, dynamic>;
      return map[key]?.toString();
    } catch (_) {
      return null;
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:8080',
    ),
  );
});
