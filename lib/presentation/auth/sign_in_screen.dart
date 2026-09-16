import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/entities.dart';
import '../core/providers.dart';
import '../core/widgets.dart';

/// GitHub Device Flow sign-in (docs/08_ui_spec.md §3.1).
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final l = context.l10n;
    final controller = ref.read(authControllerProvider.notifier);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_stories,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'GitScholar',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(l.signInTagline, textAlign: TextAlign.center),
                    const SizedBox(height: 32),
                    switch (auth) {
                      AsyncData(value: PendingDeviceCode() && final pending) =>
                        _DeviceCodeCard(
                          pending: pending,
                          onCancel: controller.cancelSignIn,
                        ),
                      AsyncError(:final error) => Column(
                        children: [
                          FailureView(error: error, compact: true),
                          FilledButton(
                            onPressed: controller.signIn,
                            child: Text(l.retry),
                          ),
                        ],
                      ),
                      AsyncLoading() => const CircularProgressIndicator(),
                      _ => FilledButton.icon(
                        key: const Key('signInButton'),
                        onPressed: controller.signIn,
                        icon: const Icon(Icons.login),
                        label: Text(l.signInWithGitHub),
                      ),
                    },
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceCodeCard extends StatefulWidget {
  const _DeviceCodeCard({required this.pending, required this.onCancel});

  final PendingDeviceCode pending;
  final VoidCallback onCancel;

  @override
  State<_DeviceCodeCard> createState() => _DeviceCodeCardState();
}

class _DeviceCodeCardState extends State<_DeviceCodeCard> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final remaining = widget.pending.expiresAt.difference(DateTime.now());
    final mm = remaining.inMinutes.clamp(0, 99).toString().padLeft(2, '0');
    final ss = (remaining.inSeconds % 60)
        .clamp(0, 59)
        .toString()
        .padLeft(2, '0');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(l.signInEnterCode),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(text: widget.pending.userCode),
                );
                if (context.mounted) showSnack(context, l.copied);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  widget.pending.userCode,
                  key: const Key('userCode'),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Text(l.tapToCopy, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => launchUrl(
                widget.pending.verificationUri,
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_browser),
              label: Text(l.openInBrowser),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(l.signInWaiting)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.signInExpiresIn('$mm:$ss'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(onPressed: widget.onCancel, child: Text(l.cancel)),
          ],
        ),
      ),
    );
  }
}
