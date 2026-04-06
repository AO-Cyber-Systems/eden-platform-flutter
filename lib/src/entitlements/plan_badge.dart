import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'entitlements_provider.dart';

/// Displays the current subscription plan as a styled chip/badge.
///
/// Shows nothing if there is no active subscription.
///
/// ```dart
/// EdenPlanBadge()
/// ```
class EdenPlanBadge extends ConsumerWidget {
  const EdenPlanBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(currentPlanProvider);
    if (plan == null) return const SizedBox.shrink();

    final subscription = ref.watch(currentSubscriptionProvider);
    final isActive = subscription?.isActive ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isActive
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        plan.name,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isActive
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
