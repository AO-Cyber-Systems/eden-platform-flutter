// Copyright 2026 AOCyber. All rights reserved.
//
// PlatformShell widget tests — covers the actions / userMenuBuilder slots
// added for AOID portal adoption (TRD aoid-12-01) plus a backward-compat
// regression that the legacy sidebar-only chrome still renders when no
// slot is configured.

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('PlatformShell', () {
    testWidgets('legacy: no actions / no userMenu -> no AppBar', (tester) async {
      final session = buildSession(displayName: 'Legacy User');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: const MaterialApp(
            home: PlatformShell(child: Text('BODY')),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('BODY'), findsOneWidget);
      expect(find.byType(PlatformSidebar), findsOneWidget);
    });

    testWidgets('actions slot renders provided widgets in AppBar', (tester) async {
      final session = buildSession(displayName: 'Action User');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: PlatformShell(
              title: 'Shell Title',
              actions: const [
                IconButton(
                  key: Key('search-action'),
                  icon: Icon(Icons.search),
                  onPressed: null,
                  tooltip: 'Search',
                ),
                IconButton(
                  key: Key('filter-action'),
                  icon: Icon(Icons.filter_list),
                  onPressed: null,
                  tooltip: 'Filter',
                ),
              ],
              child: const Text('BODY'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Shell Title'), findsOneWidget);
      expect(find.byKey(const Key('search-action')), findsOneWidget);
      expect(find.byKey(const Key('filter-action')), findsOneWidget);
    });

    testWidgets('userMenuBuilder receives session + renders in AppBar',
        (tester) async {
      final session =
          buildSession(displayName: 'Menu User', userId: 'user-42');
      late PlatformSession capturedSession;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: PlatformShell(
              userMenuBuilder: (ctx, s) {
                capturedSession = s;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    s.user.displayName,
                    key: const Key('user-menu-name'),
                  ),
                );
              },
              child: const Text('BODY'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byKey(const Key('user-menu-name')), findsOneWidget);
      // The sidebar also renders the display name in its footer, so we
      // assert via the keyed widget specifically rather than the raw text.
      final menuText = tester.widget<Text>(
        find.byKey(const Key('user-menu-name')),
      );
      expect(menuText.data, 'Menu User');
      expect(capturedSession.user.id, 'user-42');
    });

    testWidgets('actions + userMenuBuilder compose in order', (tester) async {
      final session = buildSession(displayName: 'Compose User');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: PlatformShell(
              title: 'Compose',
              actions: const [
                IconButton(
                  key: Key('search-action'),
                  icon: Icon(Icons.search),
                  onPressed: null,
                ),
              ],
              userMenuBuilder: (ctx, s) => Padding(
                key: const Key('user-menu'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(s.user.displayName),
              ),
              child: const Text('BODY'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byKey(const Key('search-action')), findsOneWidget);
      expect(find.byKey(const Key('user-menu')), findsOneWidget);

      // userMenu sits at the end of actions in build order.
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      final actionWidgets = appBar.actions!;
      expect(actionWidgets.length, 2);
      expect(actionWidgets.last.key, const Key('user-menu'));
    });

    testWidgets('sidebarItems forwards items-override to inner PlatformSidebar',
        (tester) async {
      final session = buildSession(displayName: 'Forward User');
      PlatformNavItem? tapped;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(AuthState.authenticated(session))),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: PlatformShell(
              userMenuBuilder: (ctx, s) => const SizedBox.shrink(),
              sidebarItems: const [
                PlatformNavItem(
                  id: 'one',
                  label: 'One',
                  icon: 'home',
                  path: '/one',
                  feature: 'app',
                  priority: 0,
                ),
                PlatformNavItem(
                  id: 'two',
                  label: 'Two',
                  icon: 'star',
                  path: '/two',
                  feature: 'app',
                  priority: 1,
                ),
              ],
              sidebarSelectedId: 'one',
              onSidebarItemSelected: (item) => tapped = item,
              child: const Text('BODY'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);

      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.id, 'two');
    });

    testWidgets('unauthenticated state returns child without chrome',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
                () => _PresetAuthNotifier(const AuthState.unauthenticated())),
            platformRepositoryProvider
                .overrideWithValue(FakePlatformRepository()),
          ],
          child: MaterialApp(
            home: PlatformShell(
              actions: const [
                IconButton(
                  icon: Icon(Icons.search),
                  onPressed: null,
                ),
              ],
              child: const Text('AUTH-SCREEN'),
            ),
          ),
        ),
      );
      await tester.pump();

      // Auth screens handle themselves — shell is a passthrough.
      expect(find.text('AUTH-SCREEN'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(PlatformSidebar), findsNothing);
    });
  });
}

/// Pins [authProvider] at a fixed [AuthState] for widget tests.
///
/// TRD 50-21 moved AuthNotifier from `StateNotifier` to riverpod 3's
/// `Notifier`, which has no constructor injection — the initial state comes
/// from `build()` instead of a `super(...)` call plus a constructor body.
///
/// `super.build()` is deliberately NOT called: it resolves the real
/// dependencies and kicks off a session restore whose async tail would
/// overwrite the very state this fixture exists to hold.
class _PresetAuthNotifier extends AuthNotifier {
  _PresetAuthNotifier(this._initialState);

  final AuthState _initialState;

  @override
  AuthState build() => _initialState;
}
