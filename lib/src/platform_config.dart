import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Platform operating mode.
enum PlatformMode {
  /// Multi-tenant B2B mode with company selection.
  b2b,

  /// Individual user B2C mode — company UI hidden, personal workspace transparent.
  b2c,
}

/// Platform-level configuration for Eden apps.
class EdenPlatformConfig {
  const EdenPlatformConfig({
    this.mode = PlatformMode.b2b,
  });

  final PlatformMode mode;

  /// Whether the platform is in B2C (individual user) mode.
  bool get isB2C => mode == PlatformMode.b2c;
}

/// Provider for platform configuration. Override in consuming app's ProviderScope
/// to set B2C mode:
/// ```dart
/// ProviderScope(
///   overrides: [
///     platformConfigProvider.overrideWithValue(
///       const EdenPlatformConfig(mode: PlatformMode.b2c),
///     ),
///   ],
///   child: const MyApp(),
/// )
/// ```
final platformConfigProvider = Provider<EdenPlatformConfig>((ref) {
  return const EdenPlatformConfig();
});
