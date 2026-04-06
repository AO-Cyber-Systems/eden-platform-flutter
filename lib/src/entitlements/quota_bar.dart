import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'entitlements_provider.dart';

/// Displays quota usage as a progress bar with a label.
///
/// Shows nothing if the feature is not a quota entitlement.
/// Changes color at 80% (warning) and 100% (danger).
///
/// ```dart
/// EdenQuotaBar(feature: 'conversations', label: 'Conversations')
/// ```
class EdenQuotaBar extends ConsumerWidget {
  final String feature;
  final String? label;

  const EdenQuotaBar({super.key, required this.feature, this.label});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quota = ref.watch(featureQuotaProvider(feature));
    if (quota == null) return const SizedBox.shrink();

    final used = quota.usedUnits ?? 0;
    final included = quota.includedUnits ?? 0;
    final percent = quota.usagePercent;
    final displayLabel = label ?? feature;

    Color barColor;
    if (percent >= 1.0) {
      barColor = Colors.red;
    } else if (percent >= 0.8) {
      barColor = Colors.orange;
    } else {
      barColor = Theme.of(context).colorScheme.primary;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(displayLabel, style: Theme.of(context).textTheme.bodySmall),
            Text(
              '$used / $included',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: percent >= 1.0 ? Colors.red : null,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent.clamp(0.0, 1.0),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            color: barColor,
            minHeight: 6,
          ),
        ),
        if (quota.softCap)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Approaching limit',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.orange),
            ),
          ),
      ],
    );
  }
}
