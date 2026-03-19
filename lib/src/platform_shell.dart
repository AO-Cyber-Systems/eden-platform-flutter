import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth/auth_provider.dart';
import 'navigation/sidebar.dart';

class PlatformShell extends ConsumerWidget {
  final Widget child;
  final String? title;

  const PlatformShell({super.key, required this.child, this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);

    if (!auth.isAuthenticated) {
      return child; // Auth screens handle themselves
    }

    return Scaffold(
      body: Row(
        children: [
          const PlatformSidebar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}
