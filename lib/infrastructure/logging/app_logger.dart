import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Logger that masks secrets (docs/02_architecture.md §8).
class AppLogger {
  AppLogger({Logger? logger})
    : _logger =
          logger ??
          Logger(
            level: kReleaseMode ? Level.warning : Level.debug,
            printer: SimplePrinter(printTime: false, colors: false),
          );

  final Logger _logger;

  static final _patterns = <RegExp>[
    RegExp(r'(Authorization:\s*)(Bearer|token)\s+\S+', caseSensitive: false),
    RegExp(
      r'''(["']?(?:access_token|api_key|x-api-key|token|device_code)["']?\s*[:=]\s*["']?)([^"',\s}]+)''',
      caseSensitive: false,
    ),
    RegExp(r'\b(sk-ant-)[A-Za-z0-9_-]+'),
    RegExp(r'\b(gh[opusr]_)[A-Za-z0-9]{8,}'),
  ];

  /// Replaces secrets in [input] with `***`.
  static String mask(String input) {
    var out = input;
    out = out.replaceAllMapped(_patterns[0], (m) => '${m[1]}${m[2]} ***');
    out = out.replaceAllMapped(_patterns[1], (m) => '${m[1]}***');
    out = out.replaceAllMapped(_patterns[2], (m) => '${m[1]}***');
    out = out.replaceAllMapped(_patterns[3], (m) => '${m[1]}***');
    return out;
  }

  void debug(String message) => _logger.d(mask(message));
  void info(String message) => _logger.i(mask(message));
  void warning(String message, [Object? error]) =>
      _logger.w(mask(message), error: error == null ? null : mask('$error'));
  void error(String message, [Object? error, StackTrace? stack]) => _logger.e(
    mask(message),
    error: error == null ? null : mask('$error'),
    stackTrace: stack,
  );
}
