import 'package:web_socket_channel/web_socket_channel.dart';

/// Stub implementation — should never be called directly.
/// The conditional import in `websocket_factory.dart` selects the correct
/// platform implementation (IO on native, web on browser).
WebSocketChannel createPlatformWebSocketChannel(
  String url, {
  Map<String, String> headers = const {},
  List<String>? protocols,
  Duration pingInterval = const Duration(seconds: 3),
}) {
  throw UnsupportedError('No WebSocket implementation for this platform');
}
