import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Abstract analytics interface that consumer apps implement for their
/// analytics backend (Mixpanel, Amplitude, PostHog, etc.).
///
/// The default provider uses [NoOpAnalyticsProvider] so the platform library
/// works without any analytics configuration.
///
/// Consumer apps override the provider in their [ProviderScope]:
/// ```dart
/// ProviderScope(
///   overrides: [
///     analyticsProvider.overrideWithValue(MyMixpanelAnalytics()),
///   ],
///   child: MyApp(),
/// )
/// ```
abstract class AnalyticsProvider {
  /// Track a named event with optional properties.
  void trackEvent(String name, [Map<String, Object>? properties]);

  /// Set the current user ID for attribution. Pass null to clear.
  void setUserId(String? userId);

  /// Set user properties (e.g., plan, company, role).
  void setUserProperties(Map<String, Object> properties);

  /// Track a screen view.
  void trackScreen(String screenName);

  /// Reset analytics state (e.g., on logout).
  void reset();
}

/// No-op implementation that silently discards all analytics calls.
/// Used as the default when no analytics backend is configured.
class NoOpAnalyticsProvider implements AnalyticsProvider {
  @override
  void trackEvent(String name, [Map<String, Object>? properties]) {}

  @override
  void setUserId(String? userId) {}

  @override
  void setUserProperties(Map<String, Object> properties) {}

  @override
  void trackScreen(String screenName) {}

  @override
  void reset() {}
}

/// Riverpod provider for the analytics interface.
/// Defaults to [NoOpAnalyticsProvider]. Override in consumer app's
/// [ProviderScope] to use a real analytics backend.
final analyticsProvider = Provider<AnalyticsProvider>((ref) {
  return NoOpAnalyticsProvider();
});
