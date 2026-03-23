class PlatformUser {
  final String id;
  final String email;
  final String displayName;
  final bool isActive;
  final DateTime? createdAt;

  const PlatformUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.isActive,
    this.createdAt,
  });
}

class PlatformCompany {
  final String id;
  final String name;
  final String slug;
  final String companyType;

  const PlatformCompany({
    required this.id,
    required this.name,
    required this.slug,
    required this.companyType,
  });
}

class PlatformNavItem {
  final String id;
  final String label;
  final String icon;
  final String path;
  final String feature;
  final int priority;
  final int badgeCount;

  const PlatformNavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.path,
    required this.feature,
    required this.priority,
    this.badgeCount = 0,
  });

  PlatformNavItem copyWith({
    String? id,
    String? label,
    String? icon,
    String? path,
    String? feature,
    int? priority,
    int? badgeCount,
  }) {
    return PlatformNavItem(
      id: id ?? this.id,
      label: label ?? this.label,
      icon: icon ?? this.icon,
      path: path ?? this.path,
      feature: feature ?? this.feature,
      priority: priority ?? this.priority,
      badgeCount: badgeCount ?? this.badgeCount,
    );
  }
}

class PlatformSession {
  final String accessToken;
  final String refreshToken;
  final PlatformUser user;
  final String? companyId;
  final String? role;

  const PlatformSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.companyId,
    this.role,
  });
}
