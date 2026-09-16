import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/services/file_kind_detector.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Shown for binary, unknown or oversized files (FR-35).
class UnsupportedFileView extends ConsumerWidget {
  const UnsupportedFileView({
    super.key,
    required this.path,
    this.size,
    this.tooLarge = false,
  });

  final String path;
  final int? size;
  final bool tooLarge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = ref.watch(currentWorkspaceProvider).value;
    return EmptyState(
      icon: fileIcon(FileKindDetector.fromPath(path)),
      message: [
        path.split('/').last,
        if (size != null) formatBytes(size!),
        tooLarge ? l.fileTooLarge : l.fileUnsupported,
      ].join('\n'),
      action: ws == null
          ? null
          : FilledButton.tonalIcon(
              onPressed: () => launchUrl(
                Uri.parse(
                  'https://github.com/${ws.repo.fullName}/blob/${Uri.encodeComponent(ws.branch)}/$path',
                ),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_browser),
              label: Text(l.openInBrowser),
            ),
    );
  }
}
