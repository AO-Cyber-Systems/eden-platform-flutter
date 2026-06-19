import 'package:flutter/material.dart';

/// Display descriptor for a consumer social-login provider button.
///
/// [id] is the wire value passed to `AuthNotifier.loginWithSocial` and the
/// backend `InitiateSocialLogin` RPC (`google` | `apple` | `microsoft` |
/// `facebook` | `x`). [label] and [icon] are presentation only.
@immutable
class SocialLoginProvider {
  const SocialLoginProvider({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

/// The five consumer social-login providers, in display order. Shared by the
/// platform login screen and product-specific login screens so the button set
/// stays consistent. Material `Icons` are placeholders — products may swap in
/// brand glyphs without changing the wire [SocialLoginProvider.id].
const List<SocialLoginProvider> kSocialLoginProviders = <SocialLoginProvider>[
  SocialLoginProvider(id: 'google', label: 'Google', icon: Icons.g_mobiledata),
  SocialLoginProvider(id: 'apple', label: 'Apple', icon: Icons.apple),
  SocialLoginProvider(
      id: 'microsoft', label: 'Microsoft', icon: Icons.window),
  SocialLoginProvider(
      id: 'facebook', label: 'Facebook', icon: Icons.facebook),
  SocialLoginProvider(id: 'x', label: 'X', icon: Icons.close),
];
