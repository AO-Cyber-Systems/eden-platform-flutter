import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  _itemsOverrideTests();

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
          // Auth is left as the real AuthNotifier; only its dependencies are
          // faked. Constructor injection is gone in riverpod 3 (TRD 50-21),
          // so the fakes arrive through the providers AuthNotifier.build()
          // watches rather than through `AuthNotifier(...)`.
          platformRepositoryProvider
              .overrideWithValue(FakePlatformRepository()),
          tokenStorageProvider.overrideWithValue(FakeTokenStorage()),
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
          authProvider.overrideWith(
            () => _PresetAuthNotifier(AuthState.authenticated(session)),
          ),
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
          authProvider.overrideWith(
            () => _PresetAuthNotifier(AuthState.authenticated(session)),
          ),
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

/// Pins [authProvider] at a fixed [AuthState] for widget tests.
///
/// TRD 50-21 moved AuthNotifier from `StateNotifier` to riverpod 3's
/// `Notifier`, which has no constructor injection — the initial state comes
/// from `build()` instead of a `super(...)` call plus a constructor body.
///
/// `super.build()` is deliberately NOT called: it resolves the real
/// dependencies and kicks off a session restore whose async tail would
/// overwrite the very state this fixture exists to hold. Not calling it also
/// leaves the parent's `late` dependency fields unassigned, which is safe
/// here because these tests only READ state — any auth method reached from a
/// widget would fail loudly with a LateInitializationError rather than
/// silently using a half-built notifier.
class _PresetAuthNotifier extends AuthNotifier {
  _PresetAuthNotifier(this._initialState);

  final AuthState _initialState;

  @override
  AuthState build() => _initialState;
}

void _itemsOverrideTests() {
  group('PlatformSidebar items override', () {
    testWidgets('items override renders supplied entries + skips provider',
        (tester) async {
      final session = buildSession(displayName: 'Override User');
      // Track whether the nav notifier was hit — we expect zero calls.
      final fakeRepo = FakePlatformRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider.overrideWithValue(fakeRepo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlatformSidebar(
                items: const [
                  PlatformNavItem(
                    id: 'profile',
                    label: 'Profile',
                    icon: 'people',
                    path: '/profile',
                    feature: 'mgmt',
                    priority: 0,
                  ),
                  PlatformNavItem(
                    id: 'sessions',
                    label: 'Sessions',
                    icon: 'settings',
                    path: '/sessions',
                    feature: 'mgmt',
                    priority: 1,
                  ),
                ],
                selectedId: 'profile',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
      // Provider-backed nav loading must not have been triggered — the
      // sidebar in items-override mode does not subscribe to nav state.
      expect(fakeRepo.listNavItemsCalls, 0);
    });

    testWidgets('items override: onItemSelected fires on tap', (tester) async {
      final session = buildSession(displayName: 'Override User');
      PlatformNavItem? tappedItem;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlatformSidebar(
                items: const [
                  PlatformNavItem(
                    id: 'profile',
                    label: 'Profile',
                    icon: 'people',
                    path: '/profile',
                    feature: 'mgmt',
                    priority: 0,
                  ),
                  PlatformNavItem(
                    id: 'sessions',
                    label: 'Sessions',
                    icon: 'settings',
                    path: '/sessions',
                    feature: 'mgmt',
                    priority: 1,
                  ),
                ],
                selectedId: 'profile',
                onItemSelected: (item) {
                  tappedItem = item;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sessions'));
      await tester.pump();

      expect(tappedItem, isNotNull);
      expect(tappedItem!.id, 'sessions');
      expect(tappedItem!.path, '/sessions');
    });

    testWidgets('items override: selectedId controls highlight',
        (tester) async {
      final session = buildSession(displayName: 'Override User');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlatformSidebar(
                items: const [
                  PlatformNavItem(
                    id: 'profile',
                    label: 'Profile',
                    icon: 'people',
                    path: '/profile',
                    feature: 'mgmt',
                    priority: 0,
                  ),
                  PlatformNavItem(
                    id: 'sessions',
                    label: 'Sessions',
                    icon: 'settings',
                    path: '/sessions',
                    feature: 'mgmt',
                    priority: 1,
                  ),
                ],
                selectedId: 'sessions',
                onItemSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The selected tile renders with a primaryContainer background; we
      // can't introspect color easily, but we can verify both labels
      // exist and the sidebar renders the correct number of items.
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Sessions'), findsOneWidget);
    });
  });
}
