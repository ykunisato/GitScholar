import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/services/path_utils.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import 'latex.dart';

const _pathScheme = 'gitscholar-path:';

/// Splits a leading YAML front matter block (Quarto / R Markdown).
(String?, String) splitFrontMatter(String text) {
  final m = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
  if (m == null) return (null, text);
  return (m.group(1), text.substring(m.end));
}

/// Turns inline-code repository paths into internal links (docs/07 §3).
String linkifyRepositoryPaths(String text, Set<String> paths) =>
    text.replaceAllMapped(
      RegExp(r'(?<!\[)`([^`\s]+\.[A-Za-z0-9]+)`(?!\])'),
      (m) => paths.contains(m[1])
          ? '[`${m[1]}`]($_pathScheme${Uri.encodeComponent(m[1]!)})'
          : m[0]!,
    );

MarkdownConfig buildMarkdownConfig(
  BuildContext context, {
  required String basePath,
  required void Function(String path) onOpenPath,
  required Widget Function(String url) imageBuilder,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final scheme = Theme.of(context).colorScheme;
  void onTap(String url) {
    if (url.startsWith(_pathScheme)) {
      onOpenPath(Uri.decodeComponent(url.substring(_pathScheme.length)));
      return;
    }
    final internal = resolveRelativeLink(basePath, url);
    if (internal != null) {
      onOpenPath(internal);
    } else if (url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('mailto:')) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  final pre = PreConfig(
    theme: dark ? atomOneDarkTheme : githubTheme,
    textStyle: monoStyle(context, size: 13),
    decoration: BoxDecoration(
      color: context.colors.cellBackground,
      borderRadius: BorderRadius.circular(6),
    ),
  );
  final configs = <WidgetConfig>[
    pre,
    LinkConfig(
      style: TextStyle(
        color: scheme.primary,
        decoration: TextDecoration.underline,
      ),
      onTap: onTap,
    ),
    ImgConfig(builder: (url, attributes) => imageBuilder(url)),
    PConfig(
      textStyle: TextStyle(fontSize: 15, height: 1.55, color: scheme.onSurface),
    ),
  ];
  return dark
      ? MarkdownConfig.darkConfig.copy(configs: configs)
      : MarkdownConfig.defaultConfig.copy(configs: configs);
}

MarkdownGenerator buildMarkdownGenerator(BuildContext context) =>
    MarkdownGenerator(
      generators: [
        latexGenerator(Theme.of(context).brightness == Brightness.dark),
      ],
      inlineSyntaxList: [LatexSyntax()],
    );

/// Markdown rendering shared by the viewer, notebook cells and the AI pane.
class MarkdownBody extends ConsumerWidget {
  const MarkdownBody({
    super.key,
    required this.data,
    required this.basePath,
    required this.onOpenPath,
    this.linkifyPaths = false,
    this.selectable = true,
  });

  final String data;

  /// Path of the file containing this Markdown (for relative links).
  final String basePath;
  final void Function(String path) onOpenPath;
  final bool linkifyPaths;
  final bool selectable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var text = data;
    if (linkifyPaths) {
      final ws = ref.watch(currentWorkspaceProvider).value;
      if (ws != null) {
        text = linkifyRepositoryPaths(text, {for (final e in ws.blobs) e.path});
      }
    }
    return MarkdownBlock(
      data: text,
      selectable: selectable,
      config: buildMarkdownConfig(
        context,
        basePath: basePath,
        onOpenPath: onOpenPath,
        imageBuilder: (url) => RepositoryImage(url: url, basePath: basePath),
      ),
      generator: buildMarkdownGenerator(context),
    );
  }
}

/// Image from the repository (relative path) or the network.
class RepositoryImage extends ConsumerWidget {
  const RepositoryImage({super.key, required this.url, required this.basePath});

  final String url;
  final String basePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(
        url,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    }
    final path = resolveRelativeLink(basePath, url);
    if (path == null) return const Icon(Icons.broken_image_outlined);
    final file = ref.watch(fileContentProvider(path));
    return switch (file) {
      AsyncData(:final value) when !path.toLowerCase().endsWith('.svg') =>
        Image.memory(
          value.bytes,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        ),
      AsyncData() => Tooltip(
        message: path,
        child: const Icon(Icons.image_outlined),
      ),
      AsyncError() => Tooltip(
        message: path,
        child: const Icon(Icons.broken_image_outlined),
      ),
      _ => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    };
  }
}
