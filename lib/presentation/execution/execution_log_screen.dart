import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';

/// Execution log (FR-74).
class ExecutionLogScreen extends ConsumerWidget {
  const ExecutionLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final exec = ref.watch(executionServiceProvider);
    final entries = exec?.log.reversed.toList() ?? const [];
    return Scaffold(
      appBar: AppBar(title: Text(l.executionLog)),
      body: exec == null
          ? EmptyState(icon: Icons.terminal, message: l.executionNotConfigured)
          : entries.isEmpty
          ? EmptyState(icon: Icons.terminal, message: l.noRuns)
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return ExpansionTile(
                  leading: Icon(
                    e.result.hasError
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    color: e.result.hasError
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                  title: Text(
                    e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${TimeOfDay.fromDateTime(e.at).format(context)} · ${e.result.elapsed.inMilliseconds} ms',
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        e.result.toText(),
                        style: monoStyle(context, size: 12),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
