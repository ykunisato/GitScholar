import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../l10n/app_localizations.dart';
import 'providers.dart';
import 'theme.dart';

extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Localized message for an error (docs/02 §7, NFR-21).
String failureMessage(BuildContext context, Object error) {
  final l = context.l10n;
  return switch (error) {
    NetworkFailure() => l.errorNetwork,
    RateLimitFailure(:final resetAt) =>
      resetAt == null
          ? l.errorRateLimit
          : l.errorRateLimitUntil(
              TimeOfDay.fromDateTime(resetAt.toLocal()).format(context),
            ),
    AuthFailure(:final code) when code == 'no_client_id' => l.errorNoClientId,
    AuthFailure(:final code) when code == 'invalid_client_id' =>
      l.errorInvalidClientId,
    AuthFailure(:final code) when code == 'expired_token' =>
      l.errorDeviceCodeExpired,
    AuthFailure(:final code) when code == 'access_denied' =>
      l.errorAccessDenied,
    AuthFailure() => l.errorAuth,
    NotFoundFailure(:final message) => l.errorNotFound(message),
    ConflictFailure() => l.errorConflict,
    ValidationFailure(:final message) => message,
    AiFailure(:final message) => l.errorAi(message),
    AppFailure(:final message) => message,
    _ => '$error',
  };
}

/// Standard error display with optional retry.
class FailureView extends StatelessWidget {
  const FailureView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          error is NetworkFailure ? Icons.cloud_off : Icons.error_outline,
          color: scheme.error,
          size: compact ? 20 : 40,
        ),
        const SizedBox(height: 8),
        Text(failureMessage(context, error), textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onRetry,
            child: Text(context.l10n.retry),
          ),
        ],
      ],
    );
    return Center(
      child: Padding(padding: const EdgeInsets.all(24), child: content),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {SnackBarAction? action}) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.l10n.cancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> textInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? confirmLabel,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirmLabel ?? ctx.l10n.ok),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

IconData fileIcon(FileKind kind) => switch (kind) {
  FileKind.pdf => Icons.picture_as_pdf_outlined,
  FileKind.markdown => Icons.article_outlined,
  FileKind.notebook => Icons.menu_book_outlined,
  FileKind.code => Icons.code,
  FileKind.image => Icons.image_outlined,
  FileKind.text => Icons.description_outlined,
  FileKind.binary || FileKind.unknown => Icons.insert_drive_file_outlined,
};

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatTokens(int n) =>
    n < 1000 ? '$n' : '${(n / 1000).toStringAsFixed(1)}K';

/// Whether the current layout is the phone layout.
bool isPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < Breakpoints.tablet;

/// Opens [path] in the viewer and, on phones, switches to the viewer pane.
void openPath(BuildContext context, WidgetRef ref, String path) {
  ref.read(openFilesProvider.notifier).open(path);
  if (isPhone(context)) {
    ref.read(shellProvider.notifier).showPane(PhonePane.viewer);
  }
}

/// Small coloured label.
class Badge2 extends StatelessWidget {
  const Badge2(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: c)),
    );
  }
}
