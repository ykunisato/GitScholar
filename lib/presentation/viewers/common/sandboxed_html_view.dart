import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../domain/services/html_sanitizer.dart';
import '../../core/widgets.dart';

/// Shows untrusted HTML with JavaScript disabled and navigation blocked
/// (FR-37, NFR-32). Collapsed until the user asks to show it.
class SandboxedHtmlView extends StatefulWidget {
  const SandboxedHtmlView({
    super.key,
    required this.html,
    this.initiallyExpanded = false,
    this.label,
  });

  final String html;
  final bool initiallyExpanded;
  final String? label;

  /// Builds the navigation policy; exposed for tests.
  static NavigationDecision decide(NavigationRequest request) =>
      request.url == 'about:blank' || request.url.startsWith('data:')
      ? NavigationDecision.navigate
      : NavigationDecision.prevent;

  @override
  State<SandboxedHtmlView> createState() => _SandboxedHtmlViewState();
}

class _SandboxedHtmlViewState extends State<SandboxedHtmlView> {
  late bool _expanded = widget.initiallyExpanded;
  bool _js = false;
  double _height = 300;
  WebViewController? _controller;

  WebViewController _build(bool dark) {
    final c = WebViewController()
      ..setJavaScriptMode(
        _js ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      )
      ..setNavigationDelegate(
        NavigationDelegate(onNavigationRequest: SandboxedHtmlView.decide),
      );
    final body = _js ? widget.html : stripScripts(widget.html);
    c.loadHtmlString(wrapHtmlDocument(body, dark: dark));
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (!_expanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => setState(() => _expanded = true),
          icon: const Icon(Icons.html, size: 18),
          label: Text(widget.label ?? l.showHtml),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    _controller ??= _build(dark);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(_js ? Icons.warning_amber : Icons.shield_outlined, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _js ? l.jsEnabled : l.jsDisabled,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (!_js)
              TextButton(
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: l.enableJs,
                    message: l.enableJsWarning,
                    confirmLabel: l.enableJs,
                    destructive: true,
                  );
                  if (ok && mounted) {
                    setState(() {
                      _js = true;
                      _controller = null;
                    });
                  }
                },
                child: Text(l.enableJs),
              ),
            IconButton(
              icon: const Icon(Icons.expand_less),
              onPressed: () => setState(() => _expanded = false),
            ),
          ],
        ),
        SizedBox(
          height: _height,
          child: WebViewWidget(controller: _controller!),
        ),
        GestureDetector(
          onVerticalDragUpdate: (d) =>
              setState(() => _height = (_height + d.delta.dy).clamp(120, 1600)),
          child: const SizedBox(
            height: 16,
            child: Center(child: Icon(Icons.drag_handle, size: 16)),
          ),
        ),
      ],
    );
  }
}
