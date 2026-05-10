/// Rule describing a request that should NOT trigger global "session expired"
/// handling on a 401, even though it's an authed endpoint.
///
/// These are paths where 401 carries a different meaning — typically the
/// login POST itself ("wrong password") or 2FA verification ("wrong code")
/// or read-only sub-resources where a global sign-out would be jarring.
///
/// Two match modes are supported:
/// - [LoginPathRule.exact] — match when method matches and `path` exactly
///   ends with [pattern]. Use for canonical endpoints like
///   `POST /api/v1/session`.
/// - [LoginPathRule.contains] — match when method matches and `path` contains
///   [pattern]. Use for parameterised paths like
///   `GET /api/v1/conversations/{id}/messages/{msgId}/insights`.
class LoginPathRule {
  const LoginPathRule._(this.method, this.pattern, this._isContains);

  /// Match when method matches and path ENDS WITH [pattern].
  const factory LoginPathRule.exact(String method, String pattern) =
      LoginPathRule._exact;

  /// Match when method matches and path CONTAINS [pattern].
  const factory LoginPathRule.contains(String method, String pattern) =
      LoginPathRule._contains;

  const LoginPathRule._exact(String method, String pattern)
      : this._(method, pattern, false);

  const LoginPathRule._contains(String method, String pattern)
      : this._(method, pattern, true);

  final String method;
  final String pattern;
  final bool _isContains;

  /// Returns true if [path] + [method] matches this rule.
  ///
  /// Method matching is case-insensitive.
  bool matches(String path, String? method) {
    if (method == null) return false;
    if (method.toUpperCase() != this.method.toUpperCase()) return false;
    return _isContains ? path.contains(pattern) : path.endsWith(pattern);
  }
}
