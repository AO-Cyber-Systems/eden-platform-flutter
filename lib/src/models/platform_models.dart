class PlatformUser {
  final String id;
  final String email;
  final String displayName;
  final String avatarUrl;
  final bool isActive;
  final DateTime? createdAt;

  const PlatformUser({
    required this.id,
    required this.email,
    required this.displayName,
    this.avatarUrl = '',
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
  final String section;
  final int badgeCount;

  const PlatformNavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.path,
    required this.feature,
    required this.priority,
    this.section = '',
    this.badgeCount = 0,
  });

  PlatformNavItem copyWith({
    String? id,
    String? label,
    String? icon,
    String? path,
    String? feature,
    int? priority,
    String? section,
    int? badgeCount,
  }) {
    return PlatformNavItem(
      id: id ?? this.id,
      label: label ?? this.label,
      icon: icon ?? this.icon,
      path: path ?? this.path,
      feature: feature ?? this.feature,
      priority: priority ?? this.priority,
      section: section ?? this.section,
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

  /// True when the session is bound to an HTTP cookie rather than a
  /// bearer-token pair. Cookie-bound sessions carry empty [accessToken] and
  /// [refreshToken] strings — auth state is the browser's session cookie,
  /// not a Riverpod-held JWT.
  ///
  /// Consumers that need to attach Authorization headers (mobile / desktop
  /// Connect-RPC clients) must check this flag and fall back to the
  /// cookie-jar interceptor.
  final bool cookieBound;

  const PlatformSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.companyId,
    this.role,
  }) : cookieBound = false;

  /// Constructs a session whose authentication is carried by an HTTP cookie
  /// the browser (or native cookie-jar) manages out-of-band. The
  /// access/refresh token fields default to empty strings since they are not
  /// meaningful for cookie-bound flows.
  ///
  /// Use this constructor when integrating with a custom [AuthStrategy] that
  /// relies on session cookies (e.g., AOID's WhoAmI-based session probe).
  const PlatformSession.cookieBound({
    required this.user,
    this.companyId,
    this.role,
  })  : accessToken = '',
        refreshToken = '',
        cookieBound = true;
}
