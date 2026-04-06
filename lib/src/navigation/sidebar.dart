import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_provider.dart';
import '../company/company_switcher.dart';
import '../models/platform_models.dart';
import 'nav_provider.dart';

/// Maps string icon names from [NavItem] to Material [IconData].
IconData _resolveIcon(String iconName) {
  const iconMap = <String, IconData>{
    'home': Icons.home_outlined,
    'dashboard': Icons.dashboard_outlined,
    'people': Icons.people_outlined,
    'settings': Icons.settings_outlined,
    'inventory': Icons.inventory_2_outlined,
    'receipt': Icons.receipt_long_outlined,
    'calendar': Icons.calendar_today_outlined,
    'chat': Icons.chat_outlined,
    'analytics': Icons.analytics_outlined,
    'money': Icons.attach_money,
    'task': Icons.task_outlined,
    'folder': Icons.folder_outlined,
    'email': Icons.email_outlined,
    'notifications': Icons.notifications_outlined,
    'help': Icons.help_outline,
    'star': Icons.star_outline,
    // App-specific icons
    'school': Icons.school_outlined,
    'book': Icons.menu_book_outlined,
    'library': Icons.local_library_outlined,
    'article': Icons.article_outlined,
    'tag': Icons.tag,
    'award': Icons.workspace_premium_outlined,
    'mail': Icons.mail_outlined,
    'download': Icons.download_outlined,
    'send': Icons.send_outlined,
    'quote': Icons.format_quote_outlined,
    'news': Icons.newspaper_outlined,
    'mic': Icons.mic_outlined,
    'link': Icons.link,
    'layout': Icons.view_column_outlined,
  };
  return iconMap[iconName] ?? Icons.circle_outlined;
}

/// Platform sidebar that reads from [navItemsProvider] and renders navigation
/// using eden-ui-flutter's [EdenDesktopLayout] nav item model.
class PlatformSidebar extends ConsumerWidget {
  final Widget? header;
  final Widget? footer;

  const PlatformSidebar({super.key, this.header, this.footer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navState = ref.watch(navStateProvider);
    final navItems = navState.items;
    final selectedId = navState.selectedId;
    final auth = ref.watch(authProvider);

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(
            color:
                Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Column(
        children: [
          // Header with company switcher
          Padding(
            padding: const EdgeInsets.all(16),
            child: header ?? const CompanySwitcher(),
          ),
          const Divider(height: 1),
          // Nav items grouped by section
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              children: _buildGroupedNavItems(context, ref, navItems, selectedId),
            ),
          ),
          const Divider(height: 1),
          // Footer
          Padding(
            padding: const EdgeInsets.all(12),
            child: footer ??
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        (auth.user?.displayName.isNotEmpty == true
                                ? auth.user!.displayName
                                : auth.userId ?? '?')[0]
                            .toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        auth.user?.displayName ?? auth.user?.email ?? 'Account',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.logout, size: 18),
                      onPressed: () {
                        ref.read(authProvider.notifier).logout();
                      },
                      tooltip: 'Sign out',
                    ),
                  ],
                ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildGroupedNavItems(
    BuildContext context,
    WidgetRef ref,
    List<PlatformNavItem> navItems,
    String? selectedId,
  ) {
    // Group items by section
    final grouped = <String, List<PlatformNavItem>>{};
    for (final item in navItems) {
      grouped.putIfAbsent(item.section, () => []).add(item);
    }

    // Build ordered section list: empty section first, then others by priority
    final sections = grouped.keys.toList();
    sections.sort((a, b) {
      if (a.isEmpty) return -1;
      if (b.isEmpty) return 1;
      return (grouped[a]!.first.priority).compareTo(grouped[b]!.first.priority);
    });

    final widgets = <Widget>[];
    for (int i = 0; i < sections.length; i++) {
      final section = sections[i];
      final items = grouped[section]!;

      if (section.isEmpty) {
        // Top-level items without a header
        for (final item in items) {
          widgets.add(_NavItemTile(
            item: item,
            isSelected: item.id == selectedId,
            onTap: () {
              ref.read(navStateProvider.notifier).select(item.id);
              context.go(item.path);
            },
          ));
        }
        // Add divider after top-level group if there are more sections
        if (sections.length > 1) {
          widgets.add(const Divider(height: 16));
        }
      } else {
        // Section header
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              section.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.4),
              ),
            ),
          ),
        );
        // Section items
        for (final item in items) {
          widgets.add(_NavItemTile(
            item: item,
            isSelected: item.id == selectedId,
            onTap: () {
              ref.read(navStateProvider.notifier).select(item.id);
              context.go(item.path);
            },
          ));
        }
      }
    }

    return widgets;
  }
}

class _NavItemTile extends StatelessWidget {
  final PlatformNavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavItemTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isSelected
            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  _resolveIcon(item.icon),
                  size: 20,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (item.badgeCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${item.badgeCount}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
