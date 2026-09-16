import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/editing/change_diff.dart';
import '../../domain/entities/entities.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../editing/commit_sheet.dart';
import '../editing/diff_view.dart';
import '../viewers/markdown/markdown_body.dart';
import 'agent_controller.dart';

/// AI panel (docs/08_ui_spec.md §3.5).
class AgentPane extends ConsumerStatefulWidget {
  const AgentPane({super.key});

  @override
  ConsumerState<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends ConsumerState<AgentPane> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    final controller = ref.read(agentControllerProvider.notifier);
    if (!controller.isAllowed(ws.repo)) {
      final ok = await _confirmAccess(ws.repo);
      if (!ok) return;
    }
    final text = _input.text;
    _input.clear();
    await controller.send(text);
  }

  Future<bool> _confirmAccess(RepositoryRef repo) async {
    final l = context.l10n;
    var remember = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.aiAccessTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.aiAccessMessage(repo.fullName)),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: remember,
                onChanged: (v) => setLocal(() => remember = v ?? false),
                title: Text(l.dontAskAgain),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (remember) {
                  await ref
                      .read(currentWorkspaceProvider.notifier)
                      .setAiAccess(AiAccess.denied);
                }
                if (ctx.mounted) Navigator.pop(ctx, false);
              },
              child: Text(l.deny),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.allow),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (remember) {
        await ref
            .read(currentWorkspaceProvider.notifier)
            .setAiAccess(AiAccess.allowed);
      } else {
        ref.read(agentControllerProvider.notifier).allowOnce(repo.fullName);
      }
      return true;
    }
    return false;
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = ref.watch(agentControllerProvider);
    final controller = ref.read(agentControllerProvider.notifier);
    final ws = ref.watch(currentWorkspaceProvider).value;
    ref.watch(openFilesProvider);
    ref.watch(selectionProvider);
    ref.listen(
      agentControllerProvider.select((s) => s.revision),
      (_, _) => _scrollToEnd(),
    );
    final preview = controller.preview();
    final denied = ws?.repo.effectiveAiAccess == AiAccess.denied;
    final pendingProposals = state.items
        .whereType<ProposalChatItem>()
        .where((p) => p.proposal.status == ProposalStatus.pending)
        .length;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.conversation?.title ?? l.newConversation,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: l.newConversation,
                  icon: const Icon(Icons.add_comment_outlined),
                  onPressed: state.running ? null : controller.newConversation,
                ),
                IconButton(
                  tooltip: l.history,
                  icon: const Icon(Icons.history),
                  onPressed: ws == null
                      ? null
                      : () => context.push(
                          '/ws/${ws.repo.fullName}/conversations',
                        ),
                ),
              ],
            ),
          ),
          // Context indicator (FR-62, NFR-31)
          _ContextBar(preview: preview, state: state),
          const Divider(),
          Expanded(
            child: state.items.isEmpty
                ? EmptyState(
                    icon: Icons.forum_outlined,
                    message: denied ? l.aiDenied : l.agentEmpty,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: state.items.length,
                    itemBuilder: (context, i) => _ChatItemView(
                      item: state.items[i],
                      running: state.running && i == state.items.length - 1,
                    ),
                  ),
          ),
          if (pendingProposals > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: OutlinedButton.icon(
                onPressed: controller.approveAll,
                icon: const Icon(Icons.done_all),
                label: Text(l.approveAll(pendingProposals)),
              ),
            ),
          if (state.permission != null)
            _PermissionCard(request: state.permission!),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _send,
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _send,
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: l.attach,
                    icon: const Icon(Icons.attach_file),
                    onPressed: ws == null || denied
                        ? null
                        : () => _attachDialog(context, ws),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('agentInput'),
                      controller: _input,
                      focusNode: _focus,
                      enabled: ws != null && !denied,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: denied ? l.aiDenied : l.askAi,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  state.running
                      ? IconButton.filledTonal(
                          key: const Key('agentStop'),
                          tooltip: l.stop,
                          icon: const Icon(Icons.stop),
                          onPressed: controller.stop,
                        )
                      : IconButton.filled(
                          key: const Key('agentSend'),
                          tooltip: l.send,
                          icon: const Icon(Icons.send),
                          onPressed: denied ? null : _send,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _attachDialog(BuildContext context, Workspace ws) async {
    final l = context.l10n;
    final state = ref.read(agentControllerProvider);
    final controller = ref.read(agentControllerProvider.notifier);
    final paths = [for (final e in ws.blobs) e.path];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _AttachSheet(
        allPaths: paths,
        attachOpenFile: state.attachOpenFile,
        attachSelection: state.attachSelection,
        extra: state.extraPaths,
        onOpenFile: controller.setAttachOpenFile,
        onSelection: controller.setAttachSelection,
        onAdd: controller.addExtraPath,
        onRemove: controller.removeExtraPath,
        title: l.attach,
      ),
    );
  }
}

class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.preview, required this.state});

  final ContextPreview preview;
  final AgentState state;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final parts = <String>[
      if (preview.path != null)
        preview.selectionLabel == null
            ? preview.path!
            : '${preview.path} (${preview.selectionLabel})',
      ...preview.extraPaths,
      if (preview.includeTree) l.treeSummary,
    ];
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.contextSent),
          content: Text(
            parts.isEmpty
                ? l.noContext
                : '${parts.join('\n')}\n\n${l.contextExplanation}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.ok)),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(
              preview.restricted
                  ? Icons.lock_outline
                  : Icons.visibility_outlined,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                key: const Key('contextLabel'),
                preview.restricted
                    ? l.contextRestricted
                    : '${l.context}: ${parts.isEmpty ? l.noContext : parts.join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Icon(Icons.info_outline, size: 14),
          ],
        ),
      ),
    );
  }
}

class _AttachSheet extends StatefulWidget {
  const _AttachSheet({
    required this.allPaths,
    required this.attachOpenFile,
    required this.attachSelection,
    required this.extra,
    required this.onOpenFile,
    required this.onSelection,
    required this.onAdd,
    required this.onRemove,
    required this.title,
  });

  final List<String> allPaths;
  final bool attachOpenFile;
  final bool attachSelection;
  final List<String> extra;
  final ValueChanged<bool> onOpenFile;
  final ValueChanged<bool> onSelection;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;
  final String title;

  @override
  State<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<_AttachSheet> {
  late bool _open = widget.attachOpenFile;
  late bool _sel = widget.attachSelection;
  late final Set<String> _extra = {...widget.extra};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final matches = [
      for (final p in widget.allPaths)
        if (_q.isNotEmpty && p.toLowerCase().contains(_q)) p,
    ].take(50).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          SwitchListTile(
            title: Text(l.attachOpenFile),
            value: _open,
            onChanged: (v) {
              setState(() => _open = v);
              widget.onOpenFile(v);
            },
          ),
          SwitchListTile(
            title: Text(l.attachSelection),
            value: _sel,
            onChanged: (v) {
              setState(() => _sel = v);
              widget.onSelection(v);
            },
          ),
          for (final p in _extra)
            ListTile(
              dense: true,
              leading: const Icon(Icons.attach_file),
              title: Text(p),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() => _extra.remove(p));
                  widget.onRemove(p);
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l.attachOtherFile,
              ),
              onChanged: (v) => setState(() => _q = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final p in matches)
                  ListTile(
                    dense: true,
                    title: Text(p),
                    onTap: () {
                      setState(() => _extra.add(p));
                      widget.onAdd(p);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatItemView extends ConsumerWidget {
  const _ChatItemView({required this.item, required this.running});

  final ChatItem item;
  final bool running;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    switch (item) {
      case UserChatItem(:final text, :final contextLabel):
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (contextLabel != null)
                  Text(
                    '📎 $contextLabel',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                SelectableText(
                  text,
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ],
            ),
          ),
        );
      case AssistantChatItem():
        final a = item as AssistantChatItem;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (a.thinking.isNotEmpty)
                ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    l.thinkingSummary,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    Text(
                      a.thinking,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              for (final t in a.tools) _ToolCallRow(view: t),
              if (a.text.isNotEmpty)
                MarkdownBody(
                  data: a.text,
                  basePath: '',
                  linkifyPaths: true,
                  onOpenPath: (p) => openPath(context, ref, p),
                ),
              if (!a.done && running && a.text.isEmpty && a.tools.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                ),
              if (a.usage != null)
                Text(
                  l.usageFooter(
                        formatTokens(a.usage!.totalInputTokens),
                        formatTokens(a.usage!.cacheReadInputTokens),
                        formatTokens(a.usage!.outputTokens),
                      ) +
                      (a.usage!.servedByFallback
                          ? ' · ${l.servedByFallback(a.model ?? '')}'
                          : ''),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
            ],
          ),
        );
      case ProposalChatItem(:final proposal):
        return ProposalCard(proposal: proposal);
      case CommitRequestChatItem(:final request):
        return Card(
          child: ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: Text(l.commitRequested),
            subtitle: Text('${request.message}\n${request.paths.join(', ')}'),
            isThreeLine: true,
            trailing: request.status == CommitRequestStatus.awaitingUser
                ? FilledButton.tonal(
                    onPressed: () => showCommitSheet(context, request: request),
                    child: Text(l.review),
                  )
                : Text(
                    request.status == CommitRequestStatus.done
                        ? l.done
                        : l.dismissed,
                  ),
          ),
        );
      case NoticeChatItem(:final kind, :final detail):
        final (icon, text, action) = switch (kind) {
          NoticeKind.refusal => (
            Icons.block,
            detail == null ? l.refused : '${l.refused}\n$detail',
            null,
          ),
          NoticeKind.maxTokens => (
            Icons.more_horiz,
            l.maxTokensReached,
            TextButton(
              onPressed: () => ref
                  .read(agentControllerProvider.notifier)
                  .send(l.continuePrompt),
              child: Text(l.continueLabel),
            ),
          ),
          NoticeKind.toolLimit => (
            Icons.hourglass_bottom,
            l.toolLimitReached,
            TextButton(
              onPressed: () => ref
                  .read(agentControllerProvider.notifier)
                  .send(l.continuePrompt),
              child: Text(l.continueLabel),
            ),
          ),
          NoticeKind.missingKey => (
            Icons.key_off,
            l.apiKeyMissing,
            TextButton(
              onPressed: () => context.push('/settings'),
              child: Text(l.settings),
            ),
          ),
          NoticeKind.contextLarge => (
            Icons.warning_amber,
            l.contextLarge,
            TextButton(
              onPressed: ref
                  .read(agentControllerProvider.notifier)
                  .newConversation,
              child: Text(l.newConversation),
            ),
          ),
          NoticeKind.error => (
            Icons.error_outline,
            switch (detail) {
              'auth' => l.apiKeyInvalid,
              'rate_limit' => l.errorRateLimit,
              _ => l.errorAi(detail ?? ''),
            },
            null,
          ),
        };
        return Card(
          color: kind == NoticeKind.error || kind == NoticeKind.refusal
              ? scheme.errorContainer
              : null,
          child: ListTile(
            leading: Icon(icon),
            title: Text(text),
            trailing: action,
          ),
        );
    }
  }
}

class _ToolCallRow extends StatelessWidget {
  const _ToolCallRow({required this.view});

  final ToolCallView view;

  @override
  Widget build(BuildContext context) {
    final input = view.call.input;
    final summary = input['path'] ?? input['query'] ?? input['language'] ?? '';
    final result = view.result;
    final json = const JsonEncoder.withIndent('  ').convert(input);
    String clip(String s) => s.length > 2000 ? '${s.substring(0, 2000)}…' : s;
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      leading: result == null
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              result.isError ? Icons.error_outline : Icons.build_outlined,
              size: 16,
              color: result.isError
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
      title: Text(
        '${view.call.name} $summary',
        style: monoStyle(context, size: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            clip(json),
            style: monoStyle(context, size: 11),
          ),
        ),
        if (result != null) ...[
          const Divider(),
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              clip(result.content),
              style: monoStyle(context, size: 11),
            ),
          ),
        ],
      ],
    );
  }
}

final _proposalContentsProvider = FutureProvider.autoDispose
    .family<ChangeContents?, String>((ref, pendingChangeId) async {
      final ws = ref.watch(currentWorkspaceProvider).value;
      final changes = ref.watch(pendingChangesProvider).value ?? const [];
      final c = changes.where((c) => c.id == pendingChangeId).firstOrNull;
      if (ws == null || c == null) return null;
      // Compare against the current effective content (including user edits).
      final loader = ref.read(changeDiffLoaderProvider);
      final base = await loader.load(ws, c);
      try {
        final current = await ref
            .read(workspaceServiceProvider)
            .loadFile(ws, c.path);
        return ChangeContents(
          change: c,
          oldBytes: current.bytes,
          newBytes: base.newBytes,
        );
      } on Object {
        return base;
      }
    });

/// AI proposal with approve / reject (docs/07 §5.1).
class ProposalCard extends ConsumerWidget {
  const ProposalCard({super.key, required this.proposal});

  final Proposal proposal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final controller = ref.read(agentControllerProvider.notifier);
    final pending = proposal.status == ProposalStatus.pending;
    final contents = pending
        ? ref.watch(_proposalContentsProvider(proposal.pendingChangeId))
        : null;
    final stats = contents?.value?.computeStats();
    return Card(
      key: Key('proposal-${proposal.id}'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Badge2(l.proposal, color: context.colors.aiBadge),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    proposal.path,
                    style: monoStyle(context),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (stats != null)
                  Text(
                    '+${stats.added} -${stats.deleted}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (proposal.explanation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(proposal.explanation),
              ),
            if (contents?.value != null)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(l.showDiff),
                children: [
                  ChangeDiffView(contents: contents!.value!, shrinkWrap: true),
                ],
              ),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: switch (proposal.status) {
                ProposalStatus.pending => [
                  TextButton(
                    onPressed: () => openPath(context, ref, proposal.path),
                    child: Text(l.open),
                  ),
                  TextButton(
                    key: const Key('rejectProposal'),
                    onPressed: () => controller.reject(proposal),
                    child: Text(l.reject),
                  ),
                  FilledButton(
                    key: const Key('approveProposal'),
                    onPressed: () => controller.approve(proposal),
                    child: Text(l.approve),
                  ),
                ],
                ProposalStatus.approved => [
                  Icon(Icons.check, color: context.colors.diffAddedText),
                  Text(l.approved),
                ],
                ProposalStatus.rejected => [
                  const Icon(Icons.close),
                  Text(l.rejected),
                ],
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionCard extends ConsumerWidget {
  const _PermissionCard({required this.request});

  final PermissionRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final controller = ref.read(agentControllerProvider.notifier);
    final input = request.call.input;
    final code =
        input['code'] ??
        'cell ${input['cell_index'] ?? ''} ${input['path'] ?? ''}';
    return Card(
      margin: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.runCodeConfirm(request.call.name),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  '$code',
                  style: monoStyle(context, size: 12),
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => controller.respondPermission(false),
                  child: Text(l.deny),
                ),
                TextButton(
                  onPressed: () =>
                      controller.respondPermission(true, always: true),
                  child: Text(l.allowForConversation),
                ),
                FilledButton(
                  onPressed: () => controller.respondPermission(true),
                  child: Text(l.run),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
