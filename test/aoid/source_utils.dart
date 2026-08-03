// Shared source-inspection helpers for the AOID suite's source-level gates.
//
// WHY THIS FILE EXISTS: `stripComments` used to live in
// `test/aoid/riverpod_free_gate_test.dart`, which TRD 50-24 DELETED — that file
// asserted the AOID surface never resolves a riverpod symbol, the exact property
// 50-CONTEXT.md D2 rejected, so it could not be kept in any form.
//
// But it was doing double duty. Two unrelated source-level gates imported
// `stripComments` from it:
//   * test/aoid/mode/aoid_code_sink_test.dart  (3 sites)
//   * test/aoid/mode/mode_matrix_test.dart     (5 sites)
// Neither has anything to do with riverpod: they assert that the BFF code sink
// never posts a refresh token, and that the web branch never reaches a secure
// store. Deleting the gate would have taken those guards with it.
//
// So the helper was RELOCATED, not resurrected. Nothing riverpod-related came
// with it — this file contains no firewall, no closure walker, and no assertion
// about what the AOID surface may import.

/// Strips `//` line comments and `/* */` block comments.
///
/// Source-level gates need this because a whole-file `contains` cannot tell a
/// DECLARATION from a MENTION, and these files deliberately name the things they
/// forbid in order to explain why they are forbidden. Every Stage B TRD hit the
/// same problem (50-21 §5, 50-22 §6, 50-23 §7).
///
/// Block comments are removed first: doing it the other way round lets a `//`
/// inside a `/* ... */` truncate the block's terminator.
///
/// KNOWN LIMIT, and it is the reason callers must pair this with a positive
/// control: it is not a Dart parser. A `//` sequence inside a string literal
/// (a URL, say) will be treated as a comment start. Every caller in this suite
/// asserts both that the stripper removed something and that a planted real
/// violation is still detected, so a stripper that ate too much or too little
/// fails loudly rather than silently weakening the gate it serves.
String stripComments(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');
