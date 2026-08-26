import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';


// ---------------------------------------------------------------------------
// Obj 59 / TRD 59-04 — onForgotPasswordTap + the EdenSecretField swap.
//
// The group above and both of its tests are left byte-identical on purpose:
// its first test is allowlisted verbatim in .github/known-test-failures.txt,
// and CI set-diffs on "<suite path>\t<full test name>". Renaming the group
// would change that string, which would read simultaneously as a fixed test
// and a brand-new failure.
// ---------------------------------------------------------------------------

/// Phone viewport. The login screen overflows the default 600x600 surface.
Future<void> _sized(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  VoidCallback? onForgotPasswordTap,
  bool showSsoButtons = false,
}) async {
  await _sized(tester);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: PlatformLoginScreen(
          showSsoButtons: showSsoButtons,
          onForgotPasswordTap: onForgotPasswordTap,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The single [TextField] inside the password [EdenSecretField]. The email
/// field is still an EdenInput, so a bare find.byType(TextField) is ambiguous.
Finder _passwordTextField() => find.descendant(
      of: find.byType(EdenSecretField),
      matching: find.byType(TextField),
    );

bool _passwordObscured(WidgetTester tester) =>
    tester.widget<TextField>(_passwordTextField()).obscureText;

String _passwordText(WidgetTester tester) =>
    tester.widget<TextField>(_passwordTextField()).controller!.text;

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

  group('PlatformLoginScreen onForgotPasswordTap - back-compat (null)', () {
    // Case 3.
    testWidgets('null callback renders ZERO Forgot-password pixels',
        (tester) async {
      await _pumpLogin(tester);
      expect(
        find.text('Forgot password?'),
        findsNothing,
        reason: 'A null onForgotPasswordTap must render nothing at all - not a '
            'disabled button, not a SizedBox. The staff web app passes nothing '
            'and must not grow a dead affordance.',
      );
      expect(find.byType(TextButton), findsOneWidget,
          reason: 'only the Sign up TextButton exists when forgot is null');
    });

    // Case 4 - the STAFF web app's exact call shape.
    testWidgets('staff web app call shape compiles and renders', (tester) async {
      await _sized(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlatformLoginScreen(
              onLoginSuccess: () {},
              onSignUpTap: () {},
              showSsoButtons: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(PlatformLoginScreen), findsOneWidget);
      expect(find.text('Forgot password?'), findsNothing);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
    });

    // Case 5 - the NAVIGATORS app's exact call shape.
    testWidgets('navigators app call shape compiles and renders', (tester) async {
      await _sized(tester);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlatformLoginScreen(
              showSsoButtons: false,
              onLoginSuccess: () {},
              onSignUpTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(PlatformLoginScreen), findsOneWidget);
      expect(find.text('Forgot password?'), findsNothing);
      expect(find.text("Don't have an account? Sign up"), findsOneWidget);
    });

    // Case 6 - the label finders the pre-existing test relies on.
    testWidgets('EdenSecretField keeps the Password label findable as text',
        (tester) async {
      await _pumpLogin(tester);
      expect(
        find.text('Password'),
        findsOneWidget,
        reason: 'EdenSecretField renders its label as a sibling Text, so the '
            'existing find.text finder must survive the swap from EdenInput.',
      );
      expect(find.text('Email'), findsOneWidget);
    });

    // Case 7.
    testWidgets('showSsoButtons false still hides the social buttons',
        (tester) async {
      await _pumpLogin(tester);
      expect(find.text('OR'), findsNothing);
      expect(find.textContaining('Continue with'), findsNothing);
    });
  });

  group('PlatformLoginScreen onForgotPasswordTap - the new affordance', () {
    // Case 8.
    testWidgets('non-null callback renders exactly one affordance',
        (tester) async {
      await _pumpLogin(tester, onForgotPasswordTap: () {});
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    // Case 9.
    testWidgets('tapping it invokes the callback exactly once', (tester) async {
      var taps = 0;
      await _pumpLogin(tester, onForgotPasswordTap: () => taps++);

      await tester.tap(find.text('Forgot password?'));
      await tester.pump();

      expect(taps, 1, reason: 'exactly one invocation per tap');
    });

    // Case 10 - this file's convention is Semantics(identifier:), not Key().
    testWidgets('carries Semantics identifier eden-login-forgot-password',
        (tester) async {
      await _pumpLogin(tester, onForgotPasswordTap: () {});
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Semantics) {
            return false;
          }
          return w.properties.identifier == 'eden-login-forgot-password';
        }),
        findsOneWidget,
        reason: 'matches eden-login-email / -password / -submit / -signup-link',
      );
    });

    // Case 11 - relative vertical position, NOT a Column index.
    testWidgets('renders between the password field and the Sign in button',
        (tester) async {
      await _pumpLogin(tester, onForgotPasswordTap: () {});

      final passwordY = tester.getCenter(find.byType(EdenSecretField)).dy;
      final forgotY = tester.getCenter(find.text('Forgot password?')).dy;
      final signInY = tester.getCenter(find.text('Sign in')).dy;

      expect(forgotY, greaterThan(passwordY),
          reason: 'the affordance sits BELOW the password field');
      expect(forgotY, lessThan(signInY),
          reason: 'the affordance sits ABOVE the Sign in button, the placement '
              "eden-ui's own EdenLoginPage uses");
    });
  });

  group('PlatformLoginScreen password reveal toggle', () {
    // Case 12.
    testWidgets('starts obscured', (tester) async {
      await _pumpLogin(tester);
      expect(_passwordObscured(tester), isTrue);
    });

    // Case 13.
    testWidgets('tapping the reveal icon flips obscureText, and back again',
        (tester) async {
      await _pumpLogin(tester);
      expect(_passwordObscured(tester), isTrue);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      expect(_passwordObscured(tester), isFalse,
          reason: 'first tap reveals the password');

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(_passwordObscured(tester), isTrue,
          reason: 'second tap re-obscures it');
    });

    // Case 14.
    testWidgets('renders NO copy-to-clipboard affordance', (tester) async {
      await _pumpLogin(tester);
      expect(
        find.byIcon(Icons.copy),
        findsNothing,
        reason: 'EdenSecretField renders a copy button only when onCopy is '
            'registered. A password field must never register one.',
      );
    });

    // Case 15 - text preservation across a rebuild. Deliberately asserts text
    // ONLY: didUpdateWidget fires once on this rebuild because oldWidget.value
    // is the stale value, and TextEditingController.text= collapses the
    // selection unconditionally, so a caret assertion would FAIL against the
    // CORRECT implementation. The failure mode under test is text LOSS.
    testWidgets('typed text survives a rebuild triggered by _error',
        (tester) async {
      await _pumpLogin(tester);

      await tester.enterText(_passwordTextField(), 'hunter2secret');
      await tester.pump();

      // Submit with an empty email: _login() sets _error and calls setState,
      // rebuilding the screen with no network round-trip.
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(find.text('Enter your email and password.'), findsOneWidget,
          reason: 'the rebuild this case depends on must actually have happened');
      expect(
        _passwordText(tester),
        'hunter2secret',
        reason: 'the typed password was lost or the caret moved on rebuild - '
            'EdenSecretField.didUpdateWidget reassigns _controller.text '
            'whenever value changes, so onChanged must NOT call setState.',
      );
    });

    // Case 15a - the per-keystroke hazard, made visible without asserting on a
    // caret. A setState inside onChanged rebuilds on EVERY keystroke.
    testWidgets('content is correct after every single keystroke',
        (tester) async {
      await _pumpLogin(tester);

      const target = 'abcde';
      for (var i = 1; i <= target.length; i++) {
        final soFar = target.substring(0, i);
        await tester.enterText(_passwordTextField(), soFar);
        await tester.pump();
        expect(_passwordText(tester), soFar,
            reason: 'field content diverged after keystroke $i');
      }
    });

    // Case 16 - the controller was removed, so this proves the replacement
    // field is still wired to the submit path.
    testWidgets('_login() submits exactly the typed password', (tester) async {
      await _sized(tester);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(_CapturingAuthNotifier.new)],
          child: const MaterialApp(
            home: PlatformLoginScreen(showSsoButtons: false),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, 'v@example.com');
      await tester.enterText(_passwordTextField(), 'c0rrect-horse');
      await tester.pump();

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(_CapturingAuthNotifier.capturedEmail, 'v@example.com');
      expect(
        _CapturingAuthNotifier.capturedPassword,
        'c0rrect-horse',
        reason: 'the value reaching AuthNotifier.login must be the text that '
            'was typed into EdenSecretField',
      );
    });
  });

  group('PlatformLoginScreen password field accessibility', () {
    // Case 20 - the regression this swap would otherwise ship.
    testWidgets('the password field has an accessible NAME', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpLogin(tester);

      final data =
          tester.getSemantics(find.byType(EdenSecretField)).getSemanticsData();

      expect(
        data.label,
        contains('Password'),
        reason: 'the password field lost its accessible name - '
            'eden_input.dart:86-100 documents that these inputs were previously '
            'announced as a bare password with no name at all, and the label '
            'fold is what fixed it.',
      );
      expect(data.flagsCollection.isTextField, isTrue,
          reason: 'the named node must be the text field itself, not a '
              'decorative wrapper above it');

      handle.dispose();
    });

    // Case 21 - the doubling eden_input.dart:86-100 warns about. A
    // Semantics(textField: true) wrapper STACKS a second node and Flutter web
    // then emits two input elements for the one field.
    testWidgets('exactly ONE text-field semantics node exists for it',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpLogin(tester);

      var textFieldNodes = 0;
      void walk(SemanticsNode n) {
        if (n.getSemanticsData().flagsCollection.isTextField) {
          textFieldNodes++;
        }
        n.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(EdenSecretField)));

      expect(
        textFieldNodes,
        1,
        reason: 'two text-field nodes for one field doubles the tab stops and '
            'gives a screen reader two Password boxes - measured live as 4 '
            'inputs for 2 fields before eden_input.dart folded them.',
      );

      handle.dispose();
    });

    // NOT in the TRD's test list. Added because the shape the TRD originally
    // prescribed - MergeSemantics around the whole EdenSecretField - was
    // MEASURED to fold the reveal IconButton INTO the field's own node,
    // yielding a single node that is simultaneously isTextField AND isButton
    // carrying tooltip 'Reveal secret'. That costs the show/hide control its
    // independent focus stop for assistive tech. EdenInput can use
    // MergeSemantics safely only because its suffix is a NON-interactive Icon
    // (eden_input.dart:79). This pins the corrected shape.
    testWidgets('the reveal toggle keeps its OWN semantics node',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpLogin(tester);

      final fieldNode = tester.getSemantics(find.byType(EdenSecretField));

      expect(
        fieldNode.getSemanticsData().flagsCollection.isButton,
        isFalse,
        reason: 'the password field must not also be a button - that is what '
            'MergeSemantics around EdenSecretField produces, and it makes '
            'activating the field ambiguous',
      );

      var toggleNodes = 0;
      void walk(SemanticsNode n) {
        final d = n.getSemanticsData();
        if (d.flagsCollection.isButton) {
          if (d.tooltip.contains('secret')) {
            toggleNodes++;
          }
        }
        n.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(fieldNode);

      expect(toggleNodes, 1,
          reason: 'the reveal control must remain reachable as its own node');

      handle.dispose();
    });
  });

  group('PlatformSignUpScreen password reveal toggle', () {
    // Case 17 - PlatformSignUpScreen has ZERO call sites; cheap insurance on a
    // create-a-password field (the eden half of PWR-08).
    testWidgets('starts obscured and the toggle flips it', (tester) async {
      await _sized(tester);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: PlatformSignUpScreen()),
        ),
      );
      await tester.pump();

      expect(_passwordObscured(tester), isTrue);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      expect(_passwordObscured(tester), isFalse);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(_passwordObscured(tester), isTrue);

      expect(find.byIcon(Icons.copy), findsNothing);
    });
  });
}


/// Records what reaches [AuthNotifier.login]. Hand-built, mirroring the
/// _StubAuthNotifier shape the navigators repo uses at
/// test/core/router/app05_chrome_count_test.dart:52-63.
class _CapturingAuthNotifier extends AuthNotifier {
  static String? capturedEmail;
  static String? capturedPassword;

  @override
  AuthState build() {
    capturedEmail = null;
    capturedPassword = null;
    return const AuthState.unauthenticated();
  }

  @override
  Future<void> login(String email, String password) async {
    capturedEmail = email;
    capturedPassword = password;
  }

  // `{bool force}` matches eden-platform-flutter's WIDENED
  // AuthNotifier.restoreSession on the in-flight a11y branch. Dart allows an
  // override to ADD an optional named param, so this is ALSO a valid override
  // of the narrower signature on this base. Do not remove the parameter to
  // "match" whichever signature you happen to be looking at.
  @override
  Future<void> restoreSession({bool force = false}) async {}
}
