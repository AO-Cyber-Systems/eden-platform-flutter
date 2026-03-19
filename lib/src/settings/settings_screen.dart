import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_provider.dart';
import 'settings_provider.dart';
import 'settings_provider.dart' as sp;

class PlatformSettingsScreen extends ConsumerWidget {
  const PlatformSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Appearance section
          Text(
            'Appearance',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6),
                  title: const Text('Theme'),
                  trailing: SegmentedButton<sp.ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: sp.ThemeMode.light,
                        icon: Icon(Icons.light_mode, size: 18),
                      ),
                      ButtonSegment(
                        value: sp.ThemeMode.system,
                        icon: Icon(Icons.settings_brightness, size: 18),
                      ),
                      ButtonSegment(
                        value: sp.ThemeMode.dark,
                        icon: Icon(Icons.dark_mode, size: 18),
                      ),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (modes) {
                      ref
                          .read(settingsProvider.notifier)
                          .setThemeMode(modes.first);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Notifications section
          Text(
            'Notifications',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Push notifications'),
              subtitle: const Text('Receive alerts for important updates'),
              value: settings.notificationsEnabled,
              onChanged: (value) {
                ref
                    .read(settingsProvider.notifier)
                    .setNotificationsEnabled(value);
              },
            ),
          ),
          const SizedBox(height: 24),
          // Account section
          Text(
            'Account',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('User ID'),
                  subtitle: Text(auth.userId ?? 'Unknown'),
                ),
                ListTile(
                  leading: const Icon(Icons.business_outlined),
                  title: const Text('Company ID'),
                  subtitle: Text(auth.companyId ?? 'None'),
                ),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Role'),
                  subtitle: Text(auth.role ?? 'Unknown'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.logout,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Sign out',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () {
                    ref.read(authProvider.notifier).logout();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
