import 'package:flutter_riverpod/flutter_riverpod.dart';

class NavItem {
  final String id;
  final String label;
  final String icon;
  final String path;
  final String feature;
  final int priority;
  final int badgeCount;

  const NavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.path,
    this.feature = '',
    this.priority = 0,
    this.badgeCount = 0,
  });
}

final navItemsProvider = StateProvider<List<NavItem>>((ref) => []);
final selectedNavProvider = StateProvider<String?>((ref) => null);
