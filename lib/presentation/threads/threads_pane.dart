import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/entities.dart';
import '../../domain/failures.dart';
import '../core/providers.dart';
import '../core/widgets.dart';
import '../viewers/markdown/markdown_body.dart';

/// GitHub Discussions and Issues (FR-97). Tapping a row opens the thread with
/// its comments inside the same pane.
class ThreadsPane extends ConsumerStatefulWidget {
  const ThreadsPane({super.key});

  @override
  ConsumerState<ThreadsPane> createState() => _ThreadsPaneState();
}

class _ThreadsPaneState extends ConsumerState<ThreadsPane> {
  RepoThread? _open;

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return ThreadDetailView(
        thread: open,
        onBack: () => setState(() => _open = null),
      );
    }
    final l = context.l10n;
    final kind = ref.watch(threadKindProvider);
    final threads = ref.watch(threadListProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<ThreadKind>(
                  key: const Key('threadKind'),
                  segments: [
                    ButtonSegment(
                      value: ThreadKind.discussion,
                      label: Text(l.discussions),
                    ),
                    ButtonSegment(
                      value: ThreadKind.issue,
                      label: Text(l.issues),
                    ),
                  ],
                  selected: {kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      ref.read(threadKindProvider.notifier).set(s.first),
                ),
              ),
              IconButton(
                tooltip: l.refresh,
                icon: const Icon(Icons.sync),
                onPressed: () => ref.invalidate(threadListProvider),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (threads) {
            AsyncData(:final value) => _list(value),
            AsyncError(:final error) => FailureView(
              error: error,
              onRetry: () => ref.invalidate(threadListProvider),
            ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }

  Widget _list(List<RepoThread>? threads) {
    final l = context.l10n;
    if (threads == null) {
      return EmptyState(
        icon: Icons.forum_outlined,
        message: l.threadsDisabled,
        action: FilledButton.tonal(
          onPressed: () =>
              ref.read(threadKindProvider.notifier).set(ThreadKind.issue),
          child: Text(l.issues),
        ),
      );
    }
    if (threads.isEmpty) {
      return EmptyState(icon: Icons.forum_outlined, message: l.noThreads);
    }
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(threadListProvider),
      child: ListView.builder(
        itemCount: threads.length,
        itemBuilder: (context, i) {
          final t = threads[i];
          return ListTile(
            leading: Icon(
              t.kind == ThreadKind.discussion
                  ? Icons.forum_outlined
                  : (t.isOpen
                        ? Icons.error_outline
                        : Icons.check_circle_outline),
            ),
            title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                '#${t.number}',
                t.author,
                MaterialLocalizations.of(context).formatMediumDate(t.updatedAt),
                if (t.category != null) t.category!,
                if (t.kind == ThreadKind.issue && !t.isOpen) l.threadClosed,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: t.commentCount == 0
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mode_comment_outlined, size: 14),
                      const SizedBox(width: 4),
                      Text('${t.commentCount}'),
                    ],
                  ),
            onTap: () => setState(() => _open = t),
          );
        },
      ),
    );
  }
}

/// One thread with its comments and a box to reply (FR-98).
class ThreadDetailView extends ConsumerStatefulWidget {
  const ThreadDetailView({
    super.key,
    required this.thread,
    required this.onBack,
  });

  final RepoThread thread;
  final VoidCallback onBack;

  @override
  ConsumerState<ThreadDetailView> createState() => _ThreadDetailViewState();
}

class _ThreadDetailViewState extends ConsumerState<ThreadDetailView> {
  final _input = TextEditingController();
  ThreadDetail? _detail;
  Object? _error;
  var _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(currentWorkspaceProvider).value?.repo;
    if (repo == null) return;
    setState(() => _error = null);
    try {
      final d = await ref
          .read(threadServiceProvider)
          .detail(repo, widget.thread);
      if (mounted) setState(() => _detail = d);
    } on AppFailure catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _openPath(String path) => openPath(context, ref, path);

  /// Adds or removes a reaction on the opening post, or on a comment when
  /// [commentId] is given (FR-99).
  Future<void> _react(
    String? subjectId,
    ReactionKind kind, {
    required bool add,
    String? commentId,
  }) async {
    final repo = ref.read(currentWorkspaceProvider).value?.repo;
    final detail = _detail;
    if (repo == null || detail == null) return;
    if (subjectId == null || subjectId.isEmpty) return;
    try {
      final updated = await ref
          .read(threadServiceProvider)
          .react(repo, subjectId: subjectId, kind: kind, add: add);
      if (!mounted) return;
      setState(() {
        _detail = commentId == null
            ? detail.copyWith(reactions: updated)
            : detail.copyWith(
                comments: [
                  for (final c in detail.comments)
                    if (c.id == commentId) c.withReactions(updated) else c,
                ],
              );
      });
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    }
  }

  Future<void> _send() async {
    final repo = ref.read(currentWorkspaceProvider).value?.repo;
    final detail = _detail;
    final text = _input.text.trim();
    if (repo == null || detail == null || text.isEmpty || _sending) return;
    final l = context.l10n;
    setState(() => _sending = true);
    try {
      final posted = await ref
          .read(threadServiceProvider)
          .comment(repo, widget.thread, text, nodeId: detail.nodeId);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _detail = detail.copyWith(comments: [...detail.comments, posted]);
      });
      showSnack(context, l.commentPosted);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final detail = _detail;
    final error = _error;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('threadBack'),
              tooltip: l.threads,
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onBack,
            ),
            Expanded(
              child: Text(
                widget.thread.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: l.openOnGitHub,
              icon: const Icon(Icons.open_in_browser),
              onPressed: widget.thread.url.isEmpty
                  ? null
                  : () => launchUrl(
                      Uri.parse(widget.thread.url),
                      mode: LaunchMode.externalApplication,
                    ),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: error != null
              ? FailureView(error: error, onRetry: _load)
              : detail == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _Post(
                      keyPrefix: 'post',
                      author: widget.thread.author,
                      at: widget.thread.updatedAt,
                      body: detail.body,
                      onOpenPath: _openPath,
                      reactions: detail.reactions,
                      onReact: (kind, add) =>
                          _react(detail.nodeId, kind, add: add),
                    ),
                    for (final c in detail.comments)
                      _Post(
                        keyPrefix: 'comment-${c.id}',
                        author: c.author,
                        at: c.createdAt,
                        body: c.body,
                        onOpenPath: _openPath,
                        reactions: c.reactions,
                        onReact: (kind, add) =>
                            _react(c.nodeId, kind, add: add, commentId: c.id),
                      ),
                  ],
                ),
        ),
        if (detail != null) _composer(context),
      ],
    );
  }

  Widget _composer(BuildContext context) {
    final l = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('threadComment'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: l.commentHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                key: const Key('threadSend'),
                tooltip: l.addComment,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                onPressed: _sending ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Post extends StatelessWidget {
  const _Post({
    required this.keyPrefix,
    required this.author,
    required this.at,
    required this.body,
    required this.onOpenPath,
    required this.reactions,
    required this.onReact,
  });

  /// Prefix of the widget keys, so tests and taps can tell posts apart.
  final String keyPrefix;

  final String author;
  final DateTime at;
  final String body;
  final void Function(String path) onOpenPath;
  final List<Reaction> reactions;

  /// Called with the kind and whether it should be added or removed.
  final void Function(ReactionKind kind, bool add) onReact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(author, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 8),
                Text(
                  MaterialLocalizations.of(context).formatMediumDate(at),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (body.trim().isEmpty)
              const SelectableText('—')
            else
              MarkdownBody(data: body, basePath: '', onOpenPath: onOpenPath),
            const SizedBox(height: 8),
            _ReactionBar(
              keyPrefix: keyPrefix,
              reactions: reactions,
              onReact: onReact,
            ),
          ],
        ),
      ),
    );
  }
}

/// Emoji reactions under a post, with a picker for the rest (FR-99).
class _ReactionBar extends StatelessWidget {
  const _ReactionBar({
    required this.keyPrefix,
    required this.reactions,
    required this.onReact,
  });

  final String keyPrefix;
  final List<Reaction> reactions;
  final void Function(ReactionKind kind, bool add) onReact;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final mine = {
      for (final r in reactions)
        if (r.mine) r.kind,
    };
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final r in reactions)
          InkWell(
            key: Key('$keyPrefix-reaction-${r.kind.name}'),
            onTap: () => onReact(r.kind, !r.mine),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: r.mine
                    ? scheme.secondaryContainer
                    : scheme.surfaceContainerHighest,
                border: Border.all(
                  color: r.mine ? scheme.primary : scheme.outlineVariant,
                ),
              ),
              child: Text('${r.kind.emoji} ${r.count}'),
            ),
          ),
        PopupMenuButton<ReactionKind>(
          key: Key('$keyPrefix-addReaction'),
          tooltip: l.addReaction,
          onSelected: (kind) => onReact(kind, !mine.contains(kind)),
          itemBuilder: (ctx) => [
            for (final k in ReactionKind.values)
              PopupMenuItem(
                key: Key('pick-${k.name}'),
                value: k,
                child: Row(
                  children: [
                    Text(k.emoji, style: const TextStyle(fontSize: 20)),
                    if (mine.contains(k)) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check, size: 16, color: scheme.primary),
                    ],
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Icon(
              Icons.add_reaction_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
