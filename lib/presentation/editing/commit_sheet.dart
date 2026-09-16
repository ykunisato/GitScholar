import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scholar_agent/scholar_agent.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../../infrastructure/local/secure_store.dart';
import '../agent/agent_controller.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import 'changes_screen.dart';

/// Opens the commit sheet, optionally pre-filled from an AI commit request.
Future<void> showCommitSheet(BuildContext context, {CommitRequest? request}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => CommitSheet(request: request),
    );

class CommitSheet extends ConsumerStatefulWidget {
  const CommitSheet({super.key, this.request});

  final CommitRequest? request;

  @override
  ConsumerState<CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends ConsumerState<CommitSheet> {
  late final TextEditingController _message = TextEditingController(
    text: widget.request?.message ?? '',
  );
  final _branch = TextEditingController();
  Set<String>? _selected;
  bool _busy = false;
  bool _suggesting = false;
  bool _newBranch = false;

  @override
  void dispose() {
    _message.dispose();
    _branch.dispose();
    super.dispose();
  }

  Future<void> _commit(
    List<PendingChange> changes, {
    Set<String> overwrite = const {},
  }) async {
    final l = context.l10n;
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    final ids = [
      for (final c in changes)
        if (_selected!.contains(c.id)) c.id,
    ];
    setState(() => _busy = true);
    try {
      final out = await ref
          .read(commitServiceProvider)
          .commit(
            ws,
            ids,
            message: _message.text,
            newBranch: _newBranch ? _branch.text : null,
            overwritePaths: overwrite,
          );
      if (out.result.branch != ws.branch) {
        await ref
            .read(currentWorkspaceProvider.notifier)
            .open(ws.repo, branch: out.result.branch);
      } else {
        ref.read(currentWorkspaceProvider.notifier).replace(out.workspace);
      }
      if (widget.request != null) {
        await ref
            .read(agentServiceProvider)
            .resolveCommitRequest(widget.request!, CommitRequestStatus.done);
        ref
            .read(agentControllerProvider.notifier)
            .markCommitRequest(widget.request!.id, CommitRequestStatus.done);
      }
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(l.committed(out.result.shortSha, out.result.branch)),
          ),
        );
      }
    } on ConflictFailure catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _resolveConflict(e, changes);
    } on AppFailure catch (e) {
      if (e is AuthFailure) {
        await ref.read(authControllerProvider.notifier).onAuthFailure();
      }
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, failureMessage(context, e));
      }
    }
  }

  Future<void> _resolveConflict(
    ConflictFailure e,
    List<PendingChange> changes,
  ) async {
    final l = context.l10n;
    final paths = e.conflictingPaths;
    if (paths.isEmpty) {
      // Ref moved during commit: retry once against the new head.
      showSnack(context, l.errorConflict);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.conflictTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.conflictMessage),
            const SizedBox(height: 8),
            for (final p in paths) Text('• $p', style: monoStyle(ctx)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'review'),
            child: Text(l.conflictReview),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'others'),
            child: Text(l.conflictCommitOthers),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: Text(l.conflictDiscardMine),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'overwrite'),
            child: Text(l.conflictOverwrite),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    final conflicted = [
      for (final c in changes)
        if (paths.contains(c.path) && _selected!.contains(c.id)) c,
    ];
    switch (choice) {
      case 'overwrite':
        await _commit(changes, overwrite: paths.toSet());
      case 'discard':
        for (final c in conflicted) {
          await ref.read(editingServiceProvider).discard(c.id);
        }
        setState(() => _selected!.removeAll(conflicted.map((c) => c.id)));
        if (_selected!.isNotEmpty) await _commit(changes);
      case 'others':
        setState(() => _selected!.removeAll(conflicted.map((c) => c.id)));
        if (_selected!.isNotEmpty) await _commit(changes);
      case 'review':
        Navigator.pop(context);
        ref.read(openFilesProvider.notifier).open(paths.first);
        showSnack(context, l.conflictReviewHint);
    }
  }

  Future<void> _suggestMessage(List<PendingChange> changes) async {
    final l = context.l10n;
    final settings = ref.read(currentSettingsProvider);
    final key = await ref
        .read(secureStoreProvider)
        .read(SecureStore.apiKeyFor(settings.aiProvider));
    if (key == null) {
      if (mounted) showSnack(context, l.apiKeyMissing);
      return;
    }
    setState(() => _suggesting = true);
    try {
      final diffs = StringBuffer();
      for (final c in changes.where((c) => _selected!.contains(c.id))) {
        final contents = await ref.read(changeContentsProvider(c.id).future);
        diffs.writeln('## ${c.kind.name} ${c.path}');
        if (!contents.isBinary && c.kind != ChangeKind.delete) {
          try {
            final u = contents.unified();
            diffs.writeln(
              u.length > 8000 ? '${u.substring(0, 8000)}\n[truncated]' : u,
            );
          } on Object {
            diffs.writeln('(diff unavailable)');
          }
        }
      }
      final client = ref.read(llmClientFactoryProvider)(key);
      var suggestion = '';
      String? stopReason;
      await for (final event in client.streamTurn(
        MessageRequest.forModel(
          model: settings.aiModel,
          effort: 'low',
          maxTokens: 2000,
          showThinkingSummary: false,
          messages: [
            Message.userText(
              'Write a concise git commit message (imperative subject line '
              'under 72 characters, optional short body) for these changes. '
              'Match the language of existing notes if obvious, otherwise '
              'English. Reply with the commit message only.\n\n$diffs',
            ),
          ],
        ),
      )) {
        if (event is LlmTurnComplete) {
          suggestion = event.message.text;
          stopReason = event.stopReason;
        }
      }
      if (mounted && suggestion.isNotEmpty && stopReason != 'refusal') {
        setState(() => _message.text = suggestion.trim());
      }
    } on LlmApiException catch (e) {
      if (mounted) showSnack(context, l.errorAi(e.message));
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final changes = ref.watch(committableChangesProvider);
    final ws = ref.watch(currentWorkspaceProvider).value;
    _selected ??= {
      for (final c in changes)
        if (widget.request == null ||
            widget.request!.paths.isEmpty ||
            widget.request!.paths.contains(c.path) ||
            widget.request!.paths.contains(c.oldPath))
          c.id,
    };
    final proposals = (ref.watch(pendingChangesProvider).value ?? const [])
        .where((c) => !c.isPending)
        .length;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
        left: 16,
        right: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.commitAndPush, style: Theme.of(context).textTheme.titleLarge),
          if (ws != null)
            Text(
              l.toBranch(ws.repo.fullName, ws.branch),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (proposals > 0)
            Text(
              l.proposalsExcluded(proposals),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in changes)
                  CheckboxListTile(
                    dense: true,
                    value: _selected!.contains(c.id),
                    onChanged: _busy
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? _selected!.add(c.id)
                                : _selected!.remove(c.id),
                          ),
                    title: Text(c.path, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.kind.name),
                    secondary: c.upstreamChanged
                        ? Icon(
                            Icons.warning_amber,
                            color: Theme.of(context).colorScheme.error,
                          )
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('commitMessage'),
            controller: _message,
            minLines: 2,
            maxLines: 6,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: l.commitMessage,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: l.suggestMessage,
                icon: _suggesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                onPressed: _suggesting || _busy || _selected!.isEmpty
                    ? null
                    : () => _suggestMessage(changes),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.commitToNewBranch),
            value: _newBranch,
            onChanged: _busy ? null : (v) => setState(() => _newBranch = v),
          ),
          if (_newBranch)
            TextField(
              controller: _branch,
              decoration: InputDecoration(labelText: l.branchName),
              onChanged: (_) => setState(() {}),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('commitButton'),
            onPressed:
                _busy ||
                    _selected!.isEmpty ||
                    _message.text.trim().isEmpty ||
                    (_newBranch && _branch.text.trim().isEmpty)
                ? null
                : () => _commit(changes),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            label: Text(l.commitAndPush),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
