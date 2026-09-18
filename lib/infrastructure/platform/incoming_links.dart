import 'package:flutter/services.dart';

/// Links handed to the app by the operating system: text shared from another
/// app, or a github.com URL opened directly (FR-100).
///
/// Implemented with a method channel rather than a package so that no new
/// dependency is needed (docs/02 §6).
class IncomingLinks {
  /// Creates a receiver. [channel] is replaced in tests.
  IncomingLinks({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Name shared with the native side.
  static const channelName = 'jp.gitscholar/links';

  final MethodChannel _channel;

  /// The link that started the app, if any. Returns null on platforms that do
  /// not implement the channel.
  Future<String?> initial() async {
    try {
      return await _channel.invokeMethod<String>('getInitialLink');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Registers [onLink] for links that arrive while the app is running.
  void listen(void Function(String link) onLink) {
    _channel.setMethodCallHandler((call) async {
      final argument = call.arguments;
      if (call.method == 'onLink' && argument is String) onLink(argument);
      return null;
    });
  }
}
