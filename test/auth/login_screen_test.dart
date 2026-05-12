import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlatformLoginScreen showSsoButtons', () {
    testWidgets(
      'defaults to true and renders Microsoft + Google SSO buttons (back-compat)',
      (tester) async {
        // Phone-viewport size — login screen overflows default 600x600.
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(home: PlatformLoginScreen()),
          ),
        );
        await tester.pump();

        // Back-compat default: existing consumers (staff flutter/, other Eden
        // apps) keep seeing the SSO surface.
        expect(find.text('Sign in with Microsoft'), findsOneWidget);
        expect(find.text('Sign in with Google'), findsOneWidget);
        expect(find.text('OR'), findsOneWidget);
      },
    );

    testWidgets(
      'showSsoButtons: false hides both SSO buttons and the OR divider (Navigators mode)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: PlatformLoginScreen(showSsoButtons: false),
            ),
          ),
        );
        await tester.pump();

        // Navigators consumer path: no SSO surface.
        expect(find.text('Sign in with Microsoft'), findsNothing);
        expect(find.text('Sign in with Google'), findsNothing);
        expect(find.text('OR'), findsNothing);

        // The email + password form must still render so the volunteer can
        // sign in via politihub-go's email/password endpoint. Use label text
        // matching since EdenInput is exported from eden_ui_flutter and may
        // not be directly importable in this test file.
        expect(find.text('Email'), findsOneWidget);
        expect(find.text('Password'), findsOneWidget);
      },
    );
  });
}
