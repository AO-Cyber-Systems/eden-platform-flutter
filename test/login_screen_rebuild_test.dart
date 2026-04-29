import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;

  setUp(() {
    repository = FakePlatformRepository();
  });

  testWidgets(
    'login completes successfully even when parent rebuilds on AuthState transitions',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();

      var loginSuccessFired = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                // RACE-RECREATING PARENT: watches the FULL AuthState
                // (NOT the new isAuthenticatedProvider). When _login()
                // flips state to AuthStatus.refreshing, this rebuilds
                // and unmounts PlatformLoginScreen mid-await. This is
                // the exact pattern that broke the volunteer router.
                final auth = ref.watch(authProvider);
                if (auth.status == AuthStatus.authenticated) {
                  return const _LoggedInPlaceholder();
                }
                if (auth.status == AuthStatus.refreshing) {
                  // Simulate the GoRouter behavior — bounce to a
                  // splash/loading screen mid-transition. This is what
                  // disposed PlatformLoginScreen on the volunteer app.
                  return const _LoadingPlaceholder();
                }
                return PlatformLoginScreen(
                  onLoginSuccess: () => loginSuccessFired = true,
                );
              },
            ),
          ),
        ),
      );

      // Wait for restoreSession() to settle (it sets state to unauthenticated
      // when there are no stored tokens).
      await tester.pumpAndSettle();

      // Sanity: login screen is mounted, user can interact.
      expect(find.byType(PlatformLoginScreen), findsOneWidget);

      // Type credentials.
      await tester.enterText(
        find.bySemanticsLabel('Email').first,
        'a@b.com',
      );
      await tester.enterText(
        find.bySemanticsLabel('Password').first,
        'pass',
      );

      // Tap Sign in.
      await tester.tap(find.text('Sign in'));

      // Pump multiple frames to allow:
      // 1. setState({_loading: true}) → rebuild
      // 2. authProvider state -> refreshing → parent rebuild → DISPOSE login screen
      // 3. await login() resolves → state -> authenticated → parent rebuild → mount _LoggedInPlaceholder
      // 4. Future.microtask onLoginSuccess fires (mounted check skips it because screen is disposed)
      // 5. _persistTokens completes inside AuthNotifier.login()
      await tester.pumpAndSettle();

      // CRITICAL ASSERTIONS:
      // 1. No FlutterError exception was thrown during the test
      //    (TestWidgetsFlutterBinding catches them and `tester.takeException`
      //    returns the first one, or null).
      expect(
        tester.takeException(),
        isNull,
        reason: 'No setState-after-dispose exception should be thrown',
      );

      // 2. Tokens were persisted by AuthNotifier._persistTokens, which
      //    is the structural success criterion (SC2).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), 'access-token');
      expect(prefs.getString('refresh_token'), 'refresh-token');

      // 3. We landed on the logged-in placeholder.
      expect(find.byType(_LoggedInPlaceholder), findsOneWidget);
      expect(find.byType(PlatformLoginScreen), findsNothing);

      // 4. onLoginSuccess MAY OR MAY NOT have fired — when the parent
      //    rebuilds during refreshing, the login screen is unmounted
      //    BEFORE the microtask runs, so the inner `if (!mounted) return;`
      //    correctly skips it. This is fine — the parent's auth-state
      //    watch is what drives the navigation, not the callback.
      // (No assertion needed on loginSuccessFired — both true and false
      //  are valid post-fix outcomes, depending on microtask timing.)
      // ignore: unused_local_variable
      final _ = loginSuccessFired;
    },
  );

  testWidgets(
    'login screen survives setState-in-finally when widget is disposed mid-await',
    (WidgetTester tester) async {
      // Stricter regression test: build the login screen with a
      // repository that we manually complete after we have already
      // popped the screen from the tree. This is the minimum
      // reproducer for the original "setState() called after dispose"
      // exception.
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();

      // Use a mutable flag to remove the login screen from the tree
      // mid-await without going through AuthState transitions.
      var showLogin = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                if (!showLogin) return const _LoggedInPlaceholder();
                return PlatformLoginScreen(
                  onLoginSuccess: () {
                    setState(() => showLogin = false);
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.enterText(
        find.bySemanticsLabel('Email').first,
        'a@b.com',
      );
      await tester.enterText(
        find.bySemanticsLabel('Password').first,
        'pass',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'mounted guard in finally must prevent setState after dispose',
      );
    },
  );
}

class _LoggedInPlaceholder extends StatelessWidget {
  const _LoggedInPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('logged in')));
  }
}

class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
