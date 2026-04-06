import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'entitlements_provider.dart';

/// Conditionally renders [child] based on whether a feature is entitled.
///
/// Shows [fallback] when the feature is not allowed (defaults to nothing).
/// Shows [loading] while entitlements are still loading (defaults to nothing).
///
/// ```dart
/// EdenFeatureGate(
///   feature: 'knowledge_base',
///   child: KnowledgeBaseScreen(),
///   fallback: UpgradePrompt(feature: 'knowledge_base'),
/// )
/// ```
class EdenFeatureGate extends ConsumerWidget {
  final String feature;
  final Widget child;
  final Widget? fallback;
  final Widget? loading;

  const EdenFeatureGate({
    super.key,
    required this.feature,
    required this.child,
    this.fallback,
    this.loading,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(entitlementsStateProvider);
    if (state.isLoading) return loading ?? const SizedBox.shrink();

    final allowed = ref.watch(canUseFeatureProvider(feature));
    return allowed ? child : (fallback ?? const SizedBox.shrink());
  }
}

/// Conditionally renders [child] based on a feature flag.
///
/// ```dart
/// EdenFlagGate(
///   flag: 'new_chat_ui',
///   child: NewChatWidget(),
///   fallback: OldChatWidget(),
/// )
/// ```
class EdenFlagGate extends ConsumerWidget {
  final String flag;
  final Widget child;
  final Widget? fallback;

  const EdenFlagGate({
    super.key,
    required this.flag,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(featureFlagProvider(flag));
    return enabled ? child : (fallback ?? const SizedBox.shrink());
  }
}
