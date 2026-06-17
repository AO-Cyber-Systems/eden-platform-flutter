import 'package:eden_platform_flutter/src/auth/social_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SocialAuthService.redirectUriFor', () {
    test('web → \${origin}/auth.html', () {
      final uri = SocialAuthService.redirectUriFor(
        isWeb: true,
        webOrigin: 'https://app.justindonnaruma.us',
      );
      expect(uri, 'https://app.justindonnaruma.us/auth.html');
    });

    test('mobile → com.justindonnaruma.app deep-link callback', () {
      final uri = SocialAuthService.redirectUriFor(
        isWeb: false,
        webOrigin: 'https://ignored.example',
      );
      expect(uri, 'com.justindonnaruma.app://auth/social/callback');
    });
  });

  group('SocialAuthService.sessionFromCallbackUrl', () {
    test('parses access_token + refresh_token from callback query', () {
      final session = SocialAuthService.sessionFromCallbackUrl(
        'com.justindonnaruma.app://auth/social/callback'
        '?access_token=acc-123&refresh_token=ref-456',
      );
      expect(session.accessToken, 'acc-123');
      expect(session.refreshToken, 'ref-456');
      // Consumer social login is user-scoped: no company, no role.
      expect(session.companyId, '');
      expect(session.role, '');
      expect(session.user.id, '');
    });

    test('parses tokens from an https (web) callback url', () {
      final session = SocialAuthService.sessionFromCallbackUrl(
        'https://app.justindonnaruma.us/auth.html'
        '?access_token=web-acc&refresh_token=web-ref',
      );
      expect(session.accessToken, 'web-acc');
      expect(session.refreshToken, 'web-ref');
    });

    test('throws when access_token is missing', () {
      expect(
        () => SocialAuthService.sessionFromCallbackUrl(
          'com.justindonnaruma.app://auth/social/callback?refresh_token=ref-only',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the provider returned an error param', () {
      expect(
        () => SocialAuthService.sessionFromCallbackUrl(
          'com.justindonnaruma.app://auth/social/callback?error=access_denied',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
