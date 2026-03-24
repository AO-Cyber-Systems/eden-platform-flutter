import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:eden_platform_flutter/eden_platform.dart';

void main() {
  group('NoOpAnalyticsProvider', () {
    late NoOpAnalyticsProvider provider;

    setUp(() {
      provider = NoOpAnalyticsProvider();
    });

    test('trackEvent does not throw', () {
      expect(() => provider.trackEvent('test_event'), returnsNormally);
    });

    test('trackEvent with properties does not throw', () {
      expect(
        () => provider.trackEvent('test_event', {'key': 'value'}),
        returnsNormally,
      );
    });

    test('setUserId does not throw', () {
      expect(() => provider.setUserId('user-123'), returnsNormally);
    });

    test('setUserId with null does not throw', () {
      expect(() => provider.setUserId(null), returnsNormally);
    });

    test('setUserProperties does not throw', () {
      expect(
        () => provider.setUserProperties({'plan': 'pro', 'role': 'admin'}),
        returnsNormally,
      );
    });

    test('trackScreen does not throw', () {
      expect(() => provider.trackScreen('HomeScreen'), returnsNormally);
    });

    test('reset does not throw', () {
      expect(() => provider.reset(), returnsNormally);
    });
  });

  group('analyticsProvider', () {
    test('default returns NoOpAnalyticsProvider', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final analytics = container.read(analyticsProvider);
      expect(analytics, isA<NoOpAnalyticsProvider>());
    });

    test('can be overridden with custom implementation', () {
      final custom = _TestAnalyticsProvider();
      final container = ProviderContainer(
        overrides: [analyticsProvider.overrideWithValue(custom)],
      );
      addTearDown(container.dispose);

      final analytics = container.read(analyticsProvider);
      expect(analytics, same(custom));
    });
  });
}

class _TestAnalyticsProvider implements AnalyticsProvider {
  final List<String> events = [];

  @override
  void trackEvent(String name, [Map<String, Object>? properties]) {
    events.add(name);
  }

  @override
  void setUserId(String? userId) {}

  @override
  void setUserProperties(Map<String, Object> properties) {}

  @override
  void trackScreen(String screenName) {}

  @override
  void reset() {}
}
