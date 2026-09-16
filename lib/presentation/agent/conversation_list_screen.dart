import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../core/providers.dart';
import '../core/widgets.dart';
import 'agent_controller.dart';

final conversationsProvider = FutureProvider.autoDispose<List<Conversation>>((
  ref,
) async {
  final ws = ref.watch(currentWorkspaceProvider).value;
  ref.watch(agentControllerProvider.select((s) => s.conversation?.id));
  if (ws == null) return const [];
  return ref.read(databaseProvider).conversationsFor(ws.repo.fullName);
});

/// Saved conversations for the repository (FR-66).
class ConversationListScreen extends ConsumerWidget {
  const ConversationListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final list = ref.watch(conversationsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.history)),
      body: switch (list) {
        AsyncData(:final value) when value.isEmpty => EmptyState(
          icon: Icons.forum_outlined,
          message: l.noConversations,
        ),
        AsyncData(:final value) => ListView.builder(
          itemCount: value.length,
          itemBuilder: (context, i) {
            final c = value[i];
            return ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(c.title, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                MaterialLocalizations.of(context).formatMediumDate(c.updatedAt),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: l.delete,
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: l.delete,
                    message: l.deleteConversationConfirm,
                    confirmLabel: l.delete,
                    destructive: true,
                  );
                  if (!ok) return;
                  await ref.read(databaseProvider).deleteConversation(c.id);
                  if (ref.read(agentControllerProvider).conversation?.id ==
                      c.id) {
                    ref
                        .read(agentControllerProvider.notifier)
                        .newConversation();
                  }
                  ref.invalidate(conversationsProvider);
                },
              ),
              onTap: () async {
                await ref.read(agentControllerProvider.notifier).load(c);
                if (!context.mounted) return;
                if (isPhone(context)) {
                  ref.read(shellProvider.notifier).showPane(PhonePane.agent);
                }
                context.pop();
              },
            );
          },
        ),
        AsyncError(:final error) => FailureView(error: error),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
