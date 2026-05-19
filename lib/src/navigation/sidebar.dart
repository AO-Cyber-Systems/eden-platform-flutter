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

/// Platform sidebar that renders a navigation rail using
/// eden-ui-flutter's [EdenDesktopLayout] nav item model.
///
/// Two source-of-truth modes:
/// - **Provider-backed (default):** reads from [navStateProvider] which
///   loads items from `PlatformRepository.listNavItems`. Used by Eden CRM
///   and other apps that drive their nav from a server-side registry.
/// - **Items override:** when [items] is non-null, the sidebar renders
///   those entries directly and **skips** the backend call. The
///   [selectedId] parameter (if provided) controls highlighting; tapping
///   an item calls [onItemSelected] (if provided) so the consumer can
///   route via its own router. This mode is intended for apps with a
///   static or client-derived nav (e.g. AOID's portal).
class PlatformSidebar extends ConsumerWidget {
  final Widget? header;
  final Widget? footer;

  /// Override the nav items rendered by the sidebar. When non-null, the
  /// sidebar does not read from [navStateProvider] and the provider-backed
  /// nav loading is bypassed entirely.
  final List<PlatformNavItem>? items;

  /// Selected item id when [items] is provided. Ignored in
  /// provider-backed mode (the provider holds its own selection).
  final String? selectedId;

  /// Callback invoked when an item is tapped in items-override mode.
  /// Receives the tapped item. Defaults to `context.go(item.path)` when
  /// null — sufficient for go_router consumers that just want navigation.
  final void Function(PlatformNavItem item)? onItemSelected;

  const PlatformSidebar({
    super.key,
    this.header,
    this.footer,
    this.items,
    this.selectedId,
    this.onItemSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<PlatformNavItem> navItems;
    final String? activeId;

    if (items != null) {
      // Items-override mode: skip the provider read so the backend isn't
      // queried and we don't subscribe to nav state.
      navItems = items!;
      activeId = selectedId;
    } else {
      final navState = ref.watch(navStateProvider);
      navItems = navState.items;
      activeId = navState.selectedId;
    }

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
              children: _buildGroupedNavItems(context, ref, navItems, activeId),
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

  /// Handle a tap on a nav item. In provider-backed mode (default), updates
  /// [navStateProvider] selection and calls `context.go(item.path)`. In
  /// items-override mode, calls [onItemSelected] (if non-null) or falls
  /// back to `context.go(item.path)` so callers that just want navigation
  /// don't have to wire a callback.
  void _handleNavTap(BuildContext context, WidgetRef ref, PlatformNavItem item) {
    if (items != null) {
      final cb = onItemSelected;
      if (cb != null) {
        cb(item);
      } else {
        context.go(item.path);
      }
      return;
    }
    ref.read(navStateProvider.notifier).select(item.id);
    context.go(item.path);
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
            onTap: () => _handleNavTap(context, ref, item),
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
            onTap: () => _handleNavTap(context, ref, item),
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
