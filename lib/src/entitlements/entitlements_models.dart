// Models for subscriptions, entitlements, and feature flags.
// These mirror the Eden Biz bootstrap API response.

class PlatformPlan {
  final String id;
  final String name;
  final String interval;
  final int amount;
  final String currency;
  final Map<String, dynamic>? features;

  const PlatformPlan({
    required this.id,
    required this.name,
    required this.interval,
    required this.amount,
    required this.currency,
    this.features,
  });

  factory PlatformPlan.fromJson(Map<String, dynamic> json) {
    return PlatformPlan(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      interval: json['interval'] as String? ?? 'monthly',
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      currency: json['currency'] as String? ?? 'usd',
      features: json['features'] is Map ? Map<String, dynamic>.from(json['features'] as Map) : null,
    );
  }

  /// Price formatted as a string (e.g. "\$29").
  String get priceLabel => '\$${(amount / 100).toStringAsFixed(amount % 100 == 0 ? 0 : 2)}';
}

class PlatformSubscription {
  final String id;
  final String planId;
  final String status;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;

  const PlatformSubscription({
    required this.id,
    required this.planId,
    required this.status,
    this.currentPeriodStart,
    this.currentPeriodEnd,
  });

  factory PlatformSubscription.fromJson(Map<String, dynamic> json) {
    return PlatformSubscription(
      id: json['id'] as String? ?? '',
      planId: json['plan_id'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      currentPeriodStart: DateTime.tryParse(json['current_period_start'] as String? ?? ''),
      currentPeriodEnd: DateTime.tryParse(json['current_period_end'] as String? ?? ''),
    );
  }

  bool get isActive => status == 'active' || status == 'trialing';
}

class PlatformEntitlement {
  final String featureKey;
  final String featureType;
  final bool allowed;
  final int? includedUnits;
  final int? usedUnits;
  final int? remaining;
  final bool softCap;

  const PlatformEntitlement({
    required this.featureKey,
    required this.featureType,
    required this.allowed,
    this.includedUnits,
    this.usedUnits,
    this.remaining,
    this.softCap = false,
  });

  factory PlatformEntitlement.fromJson(Map<String, dynamic> json) {
    return PlatformEntitlement(
      featureKey: json['feature_key'] as String? ?? '',
      featureType: json['feature_type'] as String? ?? 'boolean',
      allowed: json['allowed'] as bool? ?? false,
      includedUnits: (json['included_units'] as num?)?.toInt(),
      usedUnits: (json['used_units'] as num?)?.toInt(),
      remaining: (json['remaining'] as num?)?.toInt(),
      softCap: json['soft_cap'] as bool? ?? false,
    );
  }

  bool get isQuota => featureType == 'quota';

  /// Usage as a percentage (0.0–1.0+). Returns 0 for non-quota features.
  double get usagePercent {
    if (!isQuota || includedUnits == null || includedUnits == 0) return 0;
    return (usedUnits ?? 0) / includedUnits!;
  }
}

class PlatformFeatureFlag {
  final String key;
  final bool enabled;

  const PlatformFeatureFlag({required this.key, required this.enabled});

  factory PlatformFeatureFlag.fromJson(Map<String, dynamic> json) {
    return PlatformFeatureFlag(
      key: json['key'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
    );
  }
}

class EntitlementsBootstrap {
  final PlatformSubscription? subscription;
  final PlatformPlan? plan;
  final List<PlatformEntitlement> entitlements;
  final List<PlatformFeatureFlag> featureFlags;

  const EntitlementsBootstrap({
    this.subscription,
    this.plan,
    this.entitlements = const [],
    this.featureFlags = const [],
  });

  factory EntitlementsBootstrap.fromJson(Map<String, dynamic> json) {
    return EntitlementsBootstrap(
      subscription: json['subscription'] != null
          ? PlatformSubscription.fromJson(json['subscription'] as Map<String, dynamic>)
          : null,
      plan: json['plan'] != null
          ? PlatformPlan.fromJson(json['plan'] as Map<String, dynamic>)
          : null,
      entitlements: (json['entitlements'] as List?)
              ?.map((e) => PlatformEntitlement.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      featureFlags: (json['feature_flags'] as List?)
              ?.map((f) => PlatformFeatureFlag.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
