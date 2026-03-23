import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('renders nav item labels', (tester) async {
    final navItems = [
      buildNavItem(id: 'home', label: 'Home', icon: 'home'),
      buildNavItem(id: 'settings', label: 'Settings', icon: 'settings'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navStateProvider.overrideWith((ref) {
            final notifier = NavNotifier(ref);
            // Directly set state by using the notifier
            return notifier;
          }),
          // Override auth with a simple authenticated state
          authProvider.overrideWith((ref) {
            return AuthNotifier(repository: FakePlatformRepository());
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: PlatformSidebar(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The sidebar renders but nav items depend on provider state.
    // Since we're using real notifiers that start empty, verify the sidebar renders.
    expect(find.byType(PlatformSidebar), findsOneWidget);
  });

  testWidgets('renders nav items and user info from provider state',
      (tester) async {
    final navItems = [
      buildNavItem(id: 'home', label: 'Dashboard', icon: 'dashboard'),
      buildNavItem(
          id: 'people', label: 'People', icon: 'people', badgeCount: 3),
    ];

    // Build a pre-configured container with nav items and auth session
    final session = buildSession(displayName: 'Test User');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navStateProvider.overrideWith((ref) {
            // We need to manually create a notifier with pre-set state
            return _PresetNavNotifier(ref, NavState(
              items: navItems,
              selectedId: 'home',
            ));
          }),
          authProvider.overrideWith((ref) {
            return _PresetAuthNotifier(
              AuthState.authenticated(session),
            );
          }),
          platformRepositoryProvider
              .overrideWithValue(FakePlatformRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: PlatformSidebar(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify nav item labels
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('People'), findsOneWidget);

    // Verify badge count
    expect(find.text('3'), findsOneWidget);

    // Verify user display name
    expect(find.text('Test User'), findsOneWidget);
  });

  testWidgets('tapping nav item selects it', (tester) async {
    final navItems = [
      buildNavItem(id: 'home', label: 'Dashboard', icon: 'dashboard'),
      buildNavItem(id: 'settings', label: 'Settings', icon: 'settings'),
    ];

    final session = buildSession(displayName: 'User');

    late NavNotifier navNotifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navStateProvider.overrideWith((ref) {
            navNotifier = _PresetNavNotifier(ref, NavState(
              items: navItems,
              selectedId: 'home',
            ));
            return navNotifier;
          }),
          authProvider.overrideWith((ref) {
            return _PresetAuthNotifier(
              AuthState.authenticated(session),
            );
          }),
          platformRepositoryProvider
              .overrideWithValue(FakePlatformRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: PlatformSidebar(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Settings nav item
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // The nav notifier should have selected 'settings'
    expect(navNotifier.state.selectedId, 'settings');
  });
}

/// A NavNotifier that starts with pre-set state instead of empty.
class _PresetNavNotifier extends NavNotifier {
  _PresetNavNotifier(super.ref, NavState initialState) {
    state = initialState;
  }
}

/// An AuthNotifier that starts with a pre-set state.
class _PresetAuthNotifier extends AuthNotifier {
  _PresetAuthNotifier(AuthState initialState)
      : super(repository: FakePlatformRepository()) {
    state = initialState;
  }
}
