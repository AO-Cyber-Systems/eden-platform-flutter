// The D3 GATES for the sealed AOID forms.
//
// WHY THESE ARE SOURCE-LEVEL TESTS AND NOT RUNTIME ASSERTIONS.
//
// The property under test is the ABSENCE of a member. `AoidLoginForm` contains
// the plaintext password not by guarding it but by never handing it out: there
// is no callback, no injectable controller, no builder, no public State and no
// app-declarable key through which app-owned Dart could reach it. No runtime
// test can observe a parameter that does not exist, so the only mechanical form
// this requirement can take is a scan of the source.
//
// That is an established pattern in this org, not an invention: `networking.dart`
// cites "the politihub APP-06 grep gate", and this suite already runs source
// gates in `test/aoid/mode/mode_matrix_test.dart` and
// `test/aoid/mode/aoid_code_sink_test.dart`. `custom_lint` is used nowhere in the
// org and is disproportionate machinery for one invariant.
//
// COMMENTS ARE STRIPPED BEFORE SCANNING. The widgets deliberately NAME the
// things they forbid, in order to explain why they are forbidden — a whole-file
// `contains` cannot tell a DECLARATION from a WARNING ABOUT ONE, and would make
// the required documentation unwritable. `stripComments` is the suite's shared
// helper (`test/aoid/source_utils.dart`) and its doc comment requires every
// caller to pair it with a POSITIVE CONTROL, which is test 7 below: without one,
// a stripper that ate too much would turn every gate into a vacuous pass.
//
// THE `onSubmitted` / `onSubmit` DISTINCTION IS LOAD-BEARING — see kForbidden.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../source_utils.dart';

const _loginFormPath = 'lib/src/aoid/widgets/aoid_login_form.dart';
const _mfaFormPath = 'lib/src/aoid/widgets/aoid_mfa_form.dart';
const _themePath = 'lib/src/aoid/widgets/aoid_login_theme.dart';

/// Every member that would turn a sealed form into a credential tap.
///
/// Keys are REGULAR EXPRESSIONS, not substrings, and that is deliberate:
///
///   * `\bonSubmit\b` must NOT fire on `onSubmitted`. `EdenInput.onSubmitted` is
///     LEGITIMATE when the value is discarded (`onSubmitted: (_) => _submit()`)
///     — it is how the field learns the user pressed return. A public
///     `onSubmit` parameter on OUR widget is the forbidden portal shape:
///     the portal's own password step declares
///     `final ValueChanged<String> onSubmit;` and calls
///     `widget.onSubmit(_passwordCtrl.text)`. Correct for a same-origin portal
///     that owns both halves of the exchange; forbidden here.
///     A naive `source.contains('onSubmit')` cannot express that difference —
///     it matches `onSubmitted` too — so the gate would be unsatisfiable by the
///     very widget it is meant to guard. Word boundaries express it exactly:
///     in `onSubmitted` the `t` is followed by `e`, so there is no boundary and
///     no match. Test 7 proves that discrimination rather than assuming it.
///
///   * `TextEditingController\?` targets the NULLABLE (i.e. injectable) form.
///     The sealed widget's own `final _passwordCtrl = TextEditingController();`
///     is the point of the design, not a violation. The stronger guarantee —
///     that no controller can be passed in at all — is carried by the
///     constructor-surface gate in test 2, which pins the whole parameter list.
///
/// Values are the REASON the member is forbidden. A gate that fails with
/// `Expected: false` teaches nothing; every failure here has to say what would
/// leak.
const kForbidden = <String, String>{
  r'ValueChanged<':
      'D3: a value-bearing callback hands app-owned Dart the plaintext on '
      'every edit. This is the single most direct leak available.',
  r'ValueSetter<': 'D3: the same shape as ValueChanged under a different name.',
  r'TextEditingController\?':
      'D3: an INJECTABLE controller means the consuming app holds `.text` and '
      'can read the password out of the field whenever it likes.',
  r'\bFocusNode\b':
      'D3: a caller-supplied FocusNode reaches the attached EditableTextState '
      'through its context, and with it the current TextEditingValue.',
  r'\bTextInputFormatter\b':
      'D3: formatters are handed the TextEditingValue on every edit. It is a '
      'keystroke callback with a respectable name.',
  r'\bGlobalKey\b':
      'D3: a GlobalKey<...State> parameter exposes `currentState`, and with it '
      'every private field on the State object.',
  r'\bonChanged\b':
      'D3: a per-keystroke change callback. See ValueChanged above.',
  r'\bonSubmit\b':
      'D3: this is EXACTLY the AOID portal shape (PasswordStep.onSubmit is a '
      'ValueChanged<String> that is called with the password). Correct '
      'there, forbidden here. NOTE: `onSubmitted` with a DISCARDED value '
      'is permitted and is not what this needle matches.',
  r'\bWidgetBuilder\b':
      'D3: a builder runs inside the form\'s build(), so it is the parameter '
      'that later grows a `value` argument. Take a Widget instead — the '
      'app constructs it BEFORE the form exists, so it can close over '
      'nothing the form knows.',
  r'Function\(\s*BuildContext': 'D3: a builder by another name.',
};

/// Logging sinks. A password that reaches any of these has left the process.
const kLoggingSinks = <String, String>{
  r'\bprint\(': 'D3: stdout is a sink. The password must not reach one.',
  r'\bdebugPrint\(': 'D3: debugPrint is a sink, and ships in profile builds.',
  r'\blog\(': 'D3: dart:developer log() is a sink attached to the debugger.',
  r'\bSentry\b': 'D3: a Sentry breadcrumb or event leaves the device entirely.',
};

/// Returns which forbidden needles [source] actually contains, after comments
/// are removed. Returning the LIST rather than a bool is what lets a failure
/// name the specific leak.
List<String> forbiddenHitsIn(String source, Map<String, String> needles) {
  final code = stripComments(source);
  return [
    for (final needle in needles.keys)
      if (RegExp(needle).hasMatch(code)) needle,
  ];
}

/// The parameter list of [className]'s primary constructor, comments removed.
///
/// This is the gate that actually pins the SURFACE: an absence list can only
/// forbid the leaks somebody thought of, whereas asserting the constructor's
/// parameters are EXACTLY a known set rejects the next leak too — including one
/// with a name nobody has invented yet. the spec binds AODex's login screen to
/// this surface, so it is also the compatibility contract.
String constructorParamsOf(String source, String className) {
  final code = stripComments(source);
  final match = RegExp(
    '(?:const\\s+)?$className\\s*\\(\\s*\\{(.*?)\\}\\s*\\)',
    dotAll: true,
  ).firstMatch(code);
  if (match == null) return '';
  return match.group(1)!;
}

/// The declared types of every `final` field in [source].
///
/// Used by test 6 to prove `AoidLoginTheme` carries no field of a function
/// type. A struct with a `String Function()` field is a callback wearing a
/// data structure's clothes.
List<String> finalFieldTypesIn(String source) {
  final code = stripComments(source);
  return [
    for (final m in RegExp(
      r'final\s+([A-Za-z_][\w<>,\s?.]*?)\s+\w+\s*;',
    ).allMatches(code))
      m.group(1)!.trim(),
  ];
}

bool looksFunctionTyped(String type) =>
    type.contains('Function') ||
    type.contains('Callback') ||
    type.contains('Builder') ||
    type.contains('(');

void main() {
  group('D3 — the sealed forms leak nothing because they hand out nothing', () {
    // -----------------------------------------------------------------------
    // 1. The files exist.
    //
    // This test exists to keep tests 2-6 HONEST. `File(...).readAsStringSync()`
    // on a missing file throws, but any predicate applied to an EMPTY string
    // trivially reports "no forbidden members found" — so a gate suite that
    // never checked existence would go green the moment somebody deleted the
    // widget it guards. Assert the file is there, and that it is not a stub.
    // -----------------------------------------------------------------------
    test('1. the guarded source files exist and are non-trivial', () {
      for (final path in const [_loginFormPath, _mfaFormPath, _themePath]) {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              'D3: $path is missing. Tests 2-6 scan this file for forbidden '
              'members; an absent file reads as empty and would pass every '
              'one of them vacuously.',
        );
        expect(
          file.readAsStringSync().trim().length,
          greaterThan(200),
          reason:
              'D3: $path is a stub. A near-empty file passes the absence '
              'gates without implementing anything.',
        );
      }
    });

    // -----------------------------------------------------------------------
    // 2. AoidLoginForm exposes no value-bearing API.
    // -----------------------------------------------------------------------
    test('2. AoidLoginForm exposes no value-bearing API', () {
      final src = File(_loginFormPath).readAsStringSync();

      for (final hit in forbiddenHitsIn(src, kForbidden)) {
        fail(
          'AoidLoginForm declares `$hit`.\n\n${kForbidden[hit]}\n\n'
          'See the design notes. A "convenience" API letting an app supply or '
          'observe its own password field defeats the issuer\'s containment '
          'guarantee and must not be built. Do not weaken this gate to land a '
          'feature — a gate loosened to pass is not a gate.',
        );
      }

      // The surface itself, not just the absence list.
      final params = constructorParamsOf(src, 'AoidLoginForm');
      expect(
        params,
        isNotEmpty,
        reason:
            'D3: could not find AoidLoginForm\'s constructor parameter list. '
            'The gate must read the real surface, not silently pass.',
      );
      final names = RegExp(
        r'this\.(\w+)',
      ).allMatches(params).map((m) => m.group(1)!).toSet();
      expect(
        names,
        equals({'controller', 'theme'}),
        reason:
            'D3: AoidLoginForm\'s constructor surface changed. It is exactly '
            '{super.key, controller, theme} — `controller` is the '
            'AoidNativeFlow that drives the ceremony (it exposes step/next/'
            'availableMethods, NEVER the credential) and `theme` is an '
            'input-only presentation struct. Every additional parameter is a '
            'candidate leak and the spec binds AODex\'s login screen to this '
            'exact surface.',
      );
    });

    // -----------------------------------------------------------------------
    // 3. The State class is private.
    // -----------------------------------------------------------------------
    test('3. the State classes are private, so no GlobalKey can name them', () {
      final login = stripComments(File(_loginFormPath).readAsStringSync());
      final mfa = stripComments(File(_mfaFormPath).readAsStringSync());

      expect(
        login.contains('class _AoidLoginFormState'),
        isTrue,
        reason:
            'D3: AoidLoginForm\'s State must be PRIVATE. A public '
            '`AoidLoginFormState` can be named by an app-declared '
            'GlobalKey<AoidLoginFormState>, whose `.currentState` reaches every '
            'private field on it — including the TextEditingController holding '
            'the plaintext password.',
      );
      expect(
        mfa.contains('class _AoidMfaFormState'),
        isTrue,
        reason:
            'D3: AoidMfaForm\'s State must be PRIVATE, for the same reason. A '
            'TOTP or backup code is a credential.',
      );
      expect(
        RegExp(r'class\s+Aoid(Login|Mfa)FormState').hasMatch(login + mfa),
        isFalse,
        reason:
            'D3: a PUBLIC State class exists. Making the State public is the '
            'GlobalKey escape hatch this rule exists to close.',
      );
      // A public submit() on the State is the same hole with fewer steps.
      expect(
        RegExp(r'\n\s*(Future<void>|void)\s+submit\s*\(').hasMatch(login + mfa),
        isFalse,
        reason:
            'D3: a PUBLIC submit() on the State object is reachable through '
            'the same GlobalKey path. Keep it private (`_submit`).',
      );
    });

    // -----------------------------------------------------------------------
    // 4. AoidMfaForm passes the same gate. A TOTP code is a credential.
    // -----------------------------------------------------------------------
    test('4. AoidMfaForm exposes no value-bearing API', () {
      final src = File(_mfaFormPath).readAsStringSync();

      for (final hit in forbiddenHitsIn(src, kForbidden)) {
        fail(
          'AoidMfaForm declares `$hit`.\n\n${kForbidden[hit]}\n\n'
          'D3 covers the SECOND factor too: a TOTP code and a backup code are '
          'credentials, and a backup code is a long-lived one.',
        );
      }

      final names = RegExp(r'this\.(\w+)')
          .allMatches(constructorParamsOf(src, 'AoidMfaForm'))
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        names,
        equals({'controller', 'theme'}),
        reason:
            'D3: AoidMfaForm\'s constructor surface changed. It mirrors '
            'AoidLoginForm deliberately — one sealed shape, not two.',
      );
    });

    // -----------------------------------------------------------------------
    // 5. Neither widget has a logging sink.
    // -----------------------------------------------------------------------
    test('5. neither form can log the credential', () {
      for (final path in const [_loginFormPath, _mfaFormPath, _themePath]) {
        final src = File(path).readAsStringSync();
        for (final hit in forbiddenHitsIn(src, kLoggingSinks)) {
          fail(
            '$path contains `$hit`.\n\n${kLoggingSinks[hit]}\n\n'
            'D3: containment is worthless if the value is printed on the way '
            'past. AoidError builds its messages from a fixed '
            'vocabulary precisely so a credential cannot ride out inside one; '
            'the widgets must not undo that.',
          );
        }

        // The narrower rule the sinks above only approximate: nothing may be
        // interpolated into a thrown message. `throw X('...$foo...')` is a log
        // line with extra steps — it reaches Sentry through the error handler.
        expect(
          RegExp(r'throw\s+\w+\([^)]*\$').hasMatch(stripComments(src)),
          isFalse,
          reason:
              'D3: $path builds an exception message by interpolation. An '
              'exception message is a sink — it is captured, reported and '
              'often displayed. Do not put request input in one.',
        );
      }
    });

    // -----------------------------------------------------------------------
    // 6. AoidLoginTheme carries no function-typed field.
    // -----------------------------------------------------------------------
    test('6. AoidLoginTheme is a data struct, not a callback carrier', () {
      final src = File(_themePath).readAsStringSync();

      final types = finalFieldTypesIn(src);
      expect(
        types,
        isNotEmpty,
        reason:
            'D3: no `final` fields were found in AoidLoginTheme. The gate must '
            'read real declarations rather than pass on a parse miss.',
      );
      for (final type in types) {
        expect(
          looksFunctionTyped(type),
          isFalse,
          reason:
              'D3: AoidLoginTheme declares a field of type `$type`. Every field '
              'on this struct is an INPUT. A function-typed field — '
              '`String Function()`, a WidgetBuilder, any *Callback — is how a '
              'presentation struct grows a member that RETURNS user input, '
              'which is the leak this whole the spec exists to prevent. brandMark is '
              'a Widget for exactly this reason: the app constructs it before '
              'the form exists, so it can close over nothing the form knows.',
        );
      }

      for (final hit in forbiddenHitsIn(src, kForbidden)) {
        fail('AoidLoginTheme declares `$hit`.\n\n${kForbidden[hit]}');
      }
    });

    // -----------------------------------------------------------------------
    // 7. POSITIVE CONTROL — the gates above can actually fail.
    //
    // Without this, tests 2-6 are indistinguishable from a suite of predicates
    // that never match anything. It is also the pairing `stripComments`'
    // doc comment REQUIRES of every caller: the stripper is not a Dart parser,
    // so a caller must prove it neither ate the code nor left the comments.
    //
    // Five discriminations, each of which has a way of being got wrong:
    //   (a) a real declaration IS detected;
    //   (b) the same words inside a COMMENT are NOT — the widgets have to be
    //       able to document what they forbid;
    //   (c) `onSubmitted` alone does NOT trip the `onSubmit` needle — the
    //       distinction the sealed form's own field depends on;
    //   (d) the theme's function-field predicate fires on a planted callback;
    //   (e) the logging predicate fires on a file that really prints.
    // -----------------------------------------------------------------------
    test('7. the gates can fail — positive controls', () {
      final dir = Directory.systemTemp.createTempSync('aoid-d3-gate-');
      addTearDown(() => dir.deleteSync(recursive: true));

      File write(String name, String body) =>
          File('${dir.path}/$name')..writeAsStringSync(body);

      // (a) A widget with the forbidden surface, declared for real.
      final violator = write('violator.dart', '''
class ProbeForm extends StatefulWidget {
  const ProbeForm({super.key, this.onSubmit, this.controller, this.onChanged});
  final ValueChanged<String>? onSubmit;
  final ValueSetter<String>? onCommit;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;
  final GlobalKey<ProbeFormState>? formKey;
  final WidgetBuilder? brandMark;
  final Widget Function(BuildContext context, String value)? valueBuilder;
}
''');
      final hits = forbiddenHitsIn(violator.readAsStringSync(), kForbidden);
      for (final needle in kForbidden.keys) {
        expect(
          hits,
          contains(needle),
          reason:
              'POSITIVE CONTROL FAILED: the needle `$needle` did not fire on a '
              'file that really declares it. Every other assertion in this '
              'file is therefore worthless — it would pass on a leaking '
              'widget. Fix the predicate, never the expectation.',
        );
      }

      // (b) The SAME words, but in comments. Must NOT fire: the sealed widgets
      // are required to explain what they refuse to expose.
      final commentary = write('commentary.dart', '''
// This widget deliberately has no ValueChanged<String> onSubmit, no onChanged,
// no TextEditingController? and no GlobalKey.
/* A WidgetBuilder is forbidden here too; take a Widget instead. */
class Sealed extends StatefulWidget {
  const Sealed({super.key});
}
''');
      expect(
        forbiddenHitsIn(commentary.readAsStringSync(), kForbidden),
        isEmpty,
        reason:
            'POSITIVE CONTROL FAILED (inverted): the gate fired on words that '
            'appear ONLY inside comments. That makes the required D3 '
            'documentation unwritable and pushes authors to delete the '
            'explanation rather than the leak. stripComments exists for this.',
      );
      expect(
        stripComments(commentary.readAsStringSync()).contains('ValueChanged'),
        isFalse,
        reason:
            'stripComments did not remove the commented mention, so assertion '
            '(b) above proved nothing.',
      );

      // (c) THE DISCRIMINATION THIS GATE TURNS ON. `onSubmitted` with a
      // discarded value is how EdenInput reports the return key; a public
      // `onSubmit` is the portal leak. A substring match cannot tell them
      // apart — it would flag the legitimate one and make the gate
      // unsatisfiable by the very widget it guards.
      final legitimate = write('legitimate.dart', '''
class Sealed extends StatefulWidget {
  const Sealed({super.key});
}
class _SealedState extends State<Sealed> {
  final _passwordCtrl = TextEditingController();
  Widget build(BuildContext context) => EdenInput(
        controller: _passwordCtrl,
        obscureText: true,
        onSubmitted: (_) => _submit(),
      );
}
''');
      expect(
        forbiddenHitsIn(legitimate.readAsStringSync(), kForbidden),
        isEmpty,
        reason:
            'POSITIVE CONTROL FAILED (inverted): the gate flagged '
            '`onSubmitted: (_) => _submit()`, which DISCARDS the value and is '
            'legitimate, or it flagged the widget\'s OWN non-nullable '
            'TextEditingController, which is the entire design. Use word '
            'boundaries; do not delete a needle to go green.',
      );
      expect(
        RegExp(r'\bonSubmit\b').hasMatch('onSubmitted: (_) => _submit()'),
        isFalse,
        reason:
            'The `\\bonSubmit\\b` needle matched `onSubmitted`. The word '
            'boundary is what makes tests 2 and 4 satisfiable.',
      );
      expect(
        RegExp(
          r'\bonSubmit\b',
        ).hasMatch('final ValueChanged<String> onSubmit;'),
        isTrue,
        reason:
            'The `\\bonSubmit\\b` needle no longer matches a real `onSubmit` '
            'declaration — the forbidden portal shape would now pass.',
      );

      // (d) The theme's function-field predicate.
      final leakyTheme = write('leaky_theme.dart', '''
class ProbeTheme {
  const ProbeTheme({this.headline = 'Sign in', this.reveal});
  final String headline;
  final String Function() reveal;
  final VoidCallback onTap;
}
''');
      final probeTypes = finalFieldTypesIn(leakyTheme.readAsStringSync());
      expect(
        probeTypes.where(looksFunctionTyped),
        isNotEmpty,
        reason:
            'POSITIVE CONTROL FAILED: the function-typed-field predicate did '
            'not fire on `String Function() reveal;`. Test 6 would then pass '
            'on a theme struct that can return the contents of the field.',
      );
      expect(
        probeTypes,
        contains('String'),
        reason:
            'The field-type parser missed the plain `String headline` field, '
            'so test 6 may be reading nothing at all.',
      );

      // (e) The logging predicate.
      final noisy = write('noisy.dart', '''
void f(String password) {
  print(password);
  debugPrint(password);
  Sentry.captureMessage(password);
}
''');
      expect(
        forbiddenHitsIn(noisy.readAsStringSync(), kLoggingSinks).length,
        greaterThanOrEqualTo(3),
        reason:
            'POSITIVE CONTROL FAILED: the logging-sink predicate did not fire '
            'on a file that prints the password three different ways. Test 5 '
            'would be vacuous.',
      );
    });
  });
}
