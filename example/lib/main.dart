import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: EdenPlatformExampleApp()));
}

class EdenPlatformExampleApp extends StatelessWidget {
  const EdenPlatformExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eden Platform Example',
      debugShowCheckedModeBanner: false,
      theme: EdenTheme.light(),
      darkTheme: EdenTheme.dark(),
      home: const _ExampleHome(),
    );
  }
}

class _ExampleHome extends ConsumerStatefulWidget {
  const _ExampleHome();

  @override
  ConsumerState<_ExampleHome> createState() => _ExampleHomeState();
}

class _ExampleHomeState extends ConsumerState<_ExampleHome> {
  bool _showSignUp = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final selectedNav = ref.watch(selectedNavProvider);

    if (!auth.isAuthenticated) {
      return _showSignUp
          ? PlatformSignUpScreen(
              onLoginTap: () => setState(() => _showSignUp = false),
              onSignUpSuccess: () => setState(() => _showSignUp = false),
            )
          : PlatformLoginScreen(
              onSignUpTap: () => setState(() => _showSignUp = true),
            );
    }

    return PlatformShell(
      child: switch (selectedNav) {
        'settings' => const PlatformSettingsScreen(),
        _ => _ExampleDashboard(selectedNav: selectedNav),
      },
    );
  }
}

class _ExampleDashboard extends ConsumerWidget {
  const _ExampleDashboard({required this.selectedNav});

  final String? selectedNav;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(currentCompanyProvider);
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedNav == null ? 'Dashboard' : selectedNav!.toUpperCase()),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Welcome ${auth.user?.displayName ?? auth.user?.email ?? 'User'}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              company == null
                  ? 'No active company selected'
                  : 'Current company: ${company.name} (${company.slug})',
            ),
            const SizedBox(height: 24),
            EdenCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'This example uses the generated Connect-Dart clients, the Go dev server, and the platform shell providers.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
