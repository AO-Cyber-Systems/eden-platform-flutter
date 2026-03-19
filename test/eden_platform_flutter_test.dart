import 'package:flutter_test/flutter_test.dart';
import 'package:eden_platform_flutter/eden_platform.dart';

void main() {
  test('AuthState defaults to unauthenticated', () {
    const state = AuthState();
    expect(state.isAuthenticated, false);
    expect(state.accessToken, isNull);
    expect(state.refreshToken, isNull);
    expect(state.userId, isNull);
    expect(state.companyId, isNull);
    expect(state.role, isNull);
  });

  test('AuthState copyWith preserves values', () {
    const state = AuthState(
      accessToken: 'token',
      isAuthenticated: true,
    );
    final updated = state.copyWith(userId: 'user-1');
    expect(updated.accessToken, 'token');
    expect(updated.isAuthenticated, true);
    expect(updated.userId, 'user-1');
  });
}
