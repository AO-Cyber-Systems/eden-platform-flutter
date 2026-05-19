import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth/auth_provider.dart';
import 'models/platform_models.dart';
import 'navigation/sidebar.dart';

/// Builder signature for an app-specific user menu rendered in the top-right
/// of the [PlatformShell]'s AppBar. Receives the authenticated
/// [PlatformSession] so the menu can render display name, avatar, role, etc.
typedef PlatformShellUserMenuBuilder = Widget Function(
  BuildContext context,
  PlatformSession session,
);

class PlatformShell extends ConsumerWidget {
  final Widget child;
  final String? title;

  /// App-specific actions rendered in the [AppBar.actions] slot, right of
  /// the title and before the user menu. When null, no actions are added —
  /// preserving the pre-slot behavior.
  final List<Widget>? actions;

  /// Builder for the user dropdown rendered at the far right of the
  /// [AppBar]. When null, the shell renders the legacy sidebar-only
  /// chrome with no AppBar. When provided, the shell shows a Material
  /// [AppBar] with [title], [actions], and the builder's widget pinned
  /// to the trailing edge.
  ///
  /// Apps typically pass a [PopupMenuButton] or a custom row showing the
  /// user's avatar/name + a Logout button.
  final PlatformShellUserMenuBuilder? userMenuBuilder;

  const PlatformShell({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.userMenuBuilder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);

    if (auth.status == AuthStatus.unknown || auth.status == AuthStatus.refreshing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!auth.isAuthenticated) {
      return child; // Auth screens handle themselves
    }

    // When the consumer hasn't requested any chrome (no actions, no user
    // menu), keep the legacy sidebar-only layout for backward compatibility.
    // `title` alone is insufficient to trigger an AppBar — the legacy shell
    // accepted but ignored `title:` so consumers that just pass a title
    // must continue to render exactly as before.
    final hasChrome = actions != null || userMenuBuilder != null;

    if (!hasChrome) {
      return Scaffold(
        body: Row(
          children: [
            const PlatformSidebar(),
            Expanded(child: child),
          ],
        ),
      );
    }

    // Chrome path: render an AppBar with actions + user menu.
    final session = auth.session!;
    final builtActions = <Widget>[
      ...?actions,
      if (userMenuBuilder != null) userMenuBuilder!(context, session),
    ];

    return Scaffold(
      appBar: AppBar(
        title: title != null ? Text(title!) : null,
        actions: builtActions.isEmpty ? null : builtActions,
      ),
      body: Row(
        children: [
          const PlatformSidebar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}
