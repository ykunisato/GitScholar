import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../../../domain/entities/entities.dart';
import '../../../domain/failures.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'language_map.dart';

/// Converts editor text back to the file's original line endings (docs/06 §1.1).
String restoreLineEndings(String editorText, {required bool crlf}) => crlf
    ? editorText.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')
    : editorText;

/// Code / text viewer and editor (docs/05 §4, docs/06 §1.1).
class CodeViewer extends ConsumerStatefulWidget {
  const CodeViewer({
    super.key,
    required this.file,
    required this.editing,
    this.languageOverride,
  });

  final FileContent file;
  final bool editing;
  final String? languageOverride;

  /// Autosave debounce.
  static const debounce = Duration(seconds: 1);

  @override
  ConsumerState<CodeViewer> createState() => _CodeViewerState();
}

class _CodeViewerState extends ConsumerState<CodeViewer>
    with WidgetsBindingObserver {
  late final CodeLineEditingController _controller;
  late final CodeFindController _find;
  late bool _crlf;
  late String _lastSaved;
  Timer? _timer;
  String _lastSelection = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final text = widget.file.text ?? '';
    _crlf = text.contains('\r\n');
    _lastSaved = text;
    _controller = CodeLineEditingController.fromText(
      text.replaceAll('\r\n', '\n'),
    );
    _find = CodeFindController(_controller);
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(CodeViewer old) {
    super.didUpdateWidget(old);
    final text = widget.file.text ?? '';
    if (!widget.editing && text != _lastSaved) {
      _lastSaved = text;
      _crlf = text.contains('\r\n');
      _controller.text = text.replaceAll('\r\n', '\n');
    }
    if (old.editing && !widget.editing) _flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flush();
    }
  }

  void _onChanged() {
    final sel = _controller.selection;
    final selected = sel.isCollapsed ? '' : _controller.selectedText;
    if (selected != _lastSelection) {
      _lastSelection = selected;
      ref
          .read(selectionProvider.notifier)
          .set(
            selected.isEmpty
                ? null
                : ViewerSelection(
                    path: widget.file.path,
                    text: selected,
                    startLine: sel.startIndex + 1,
                    endLine: sel.endIndex + 1,
                  ),
          );
    }
    if (!widget.editing) return;
    final text = restoreLineEndings(_controller.text, crlf: _crlf);
    if (text == _lastSaved) return;
    _timer?.cancel();
    _timer = Timer(CodeViewer.debounce, _flush);
  }

  Future<void> _flush() async {
    _timer?.cancel();
    _timer = null;
    final text = restoreLineEndings(_controller.text, crlf: _crlf);
    if (text == _lastSaved) return;
    final ws = ref.read(currentWorkspaceProvider).value;
    if (ws == null) return;
    _lastSaved = text;
    try {
      await ref
          .read(editingServiceProvider)
          .saveText(ws, widget.file.path, text);
    } on AppFailure catch (e) {
      if (mounted) showSnack(context, failureMessage(context, e));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timer != null) unawaited(_flush());
    _controller.removeListener(_onChanged);
    _find.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(currentSettingsProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (id, mode) = widget.languageOverride != null
        ? languageForName(widget.languageOverride!)
        : languageForPath(widget.file.path);
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _flush,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _flush,
      },
      child: CodeEditor(
        key: const Key('codeEditor'),
        controller: _controller,
        findController: _find,
        readOnly: !widget.editing,
        wordWrap: settings.wordWrap,
        style: CodeEditorStyle(
          fontSize: settings.editorFontSize,
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier New'],
          backgroundColor: scheme.surface,
          textColor: scheme.onSurface,
          codeTheme: CodeHighlightTheme(
            languages: {id: CodeHighlightThemeMode(mode: mode)},
            theme: dark ? atomOneDarkTheme : githubTheme,
          ),
        ),
        indicatorBuilder:
            (context, editingController, chunkController, notifier) => Row(
              children: [
                DefaultCodeLineNumber(
                  controller: editingController,
                  notifier: notifier,
                  textStyle: monoStyle(
                    context,
                    size: settings.editorFontSize * 0.85,
                    color: scheme.outline,
                  ),
                ),
                DefaultCodeChunkIndicator(
                  width: 16,
                  controller: chunkController,
                  notifier: notifier,
                ),
              ],
            ),
        findBuilder: (context, controller, readOnly) =>
            _FindBar(controller: controller),
      ),
    );
  }
}

class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar({required this.controller});

  final CodeFindController controller;

  @override
  Size get preferredSize => Size.fromHeight(controller.value == null ? 0 : 44);

  @override
  Widget build(BuildContext context) {
    if (controller.value == null) return const SizedBox.shrink();
    final l = context.l10n;
    return Material(
      elevation: 2,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller.findInputController,
                focusNode: controller.findInputFocusNode,
                decoration: InputDecoration(
                  hintText: l.find,
                  isDense: true,
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => controller.nextMatch(),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (_, value, _) {
                final result = value?.result;
                return Text(
                  result == null
                      ? ''
                      : '${result.index + 1}/${result.matches.length}',
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: controller.previousMatch,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: controller.nextMatch,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: controller.close,
            ),
          ],
        ),
      ),
    );
  }
}
