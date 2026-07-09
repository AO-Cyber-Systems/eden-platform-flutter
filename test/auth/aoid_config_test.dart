// R-ACL-04 AoidConfig TDD suite.
//
// bool.fromEnvironment/String.fromEnvironment are compile-time constants —
// a widget/provider test cannot set them per-case. AoidConfig itself takes
// explicit constructor args so it is fully testable; only
// AoidConfig.fromEnvironment() (exercised via aoid_wireup_test.dart's
// aoidConfigProvider override pattern, not here) touches the env constants.
//
// Test list (see AOID-CONSOLE-LOGIN-04-TRD.md, ported from
// eden-biz-console-login/flutter):
// Happy:
//   - explicit args expose enabled/issuer/clientId unchanged.
//   - redirectUri(origin) == '$origin/auth.html'.
// Failure:
//   - enabled=true with empty issuer throws.
//   - enabled=true with empty clientId throws.
// Edge:
//   - enabled=false with empty issuer/clientId does NOT throw (flag off ==
//     zero behavior change; nothing reads issuer/clientId in that path).

// Narrow in-package import (not the eden_platform.dart barrel) — the barrel
// re-exports src/networking/*.dart which fails to compile under the CFE
// against the resolved dio 5.10.0 (DioExceptionType.transformTimeout). See
// pkce_generator_test.dart for the full note.
import 'package:eden_platform_flutter/src/auth/aoid_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AoidConfig — explicit construction', () {
    test('exposes enabled/issuer/clientId unchanged', () {
      const cfg = AoidConfig(
        enabled: true,
        issuer: 'https://auth.aocyber.ai',
        clientId: 'eden-biz-console',
      );

      expect(cfg.enabled, isTrue);
      expect(cfg.issuer, 'https://auth.aocyber.ai');
      expect(cfg.clientId, 'eden-biz-console');
    });

    test('redirectUri(origin) appends /auth.html', () {
      const cfg = AoidConfig(
        enabled: true,
        issuer: 'https://auth.aocyber.ai',
        clientId: 'eden-biz-console',
      );

      expect(
        cfg.redirectUri('https://console.biz.aocyber.ai'),
        'https://console.biz.aocyber.ai/auth.html',
      );
    });
  });

  group('AoidConfig — fail-fast validation', () {
    test('enabled=true with empty issuer throws', () {
      expect(
        () => const AoidConfig(
          enabled: true,
          issuer: '',
          clientId: 'eden-biz-console',
        ).validate(),
        throwsA(isA<StateError>()),
      );
    });

    test('enabled=true with empty clientId throws', () {
      expect(
        () => const AoidConfig(
          enabled: true,
          issuer: 'https://auth.aocyber.ai',
          clientId: '',
        ).validate(),
        throwsA(isA<StateError>()),
      );
    });

    test('enabled=false with empty issuer/clientId does not throw', () {
      expect(
        () => const AoidConfig(
          enabled: false,
          issuer: '',
          clientId: '',
        ).validate(),
        returnsNormally,
      );
    });
  });
}
