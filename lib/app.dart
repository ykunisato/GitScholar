import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/entities/entities.dart';
import 'l10n/app_localizations.dart';
import 'presentation/core/providers.dart';
import 'presentation/core/theme.dart';
import 'router.dart';

class GitScholarApp extends ConsumerStatefulWidget {
  const GitScholarApp({super.key});

  @override
  ConsumerState<GitScholarApp> createState() => _GitScholarAppState();
}

class _GitScholarAppState extends ConsumerState<GitScholarApp> {
  @override
  void initState() {
    super.initState();
    final links = ref.read(incomingLinksProvider);
    links.listen((link) => ref.read(pendingLinkProvider.notifier).offer(link));
    links.initial().then((link) {
      if (mounted) ref.read(pendingLinkProvider.notifier).offer(link);
    });
  }

  /// Opens a shared repository link once there is somewhere to open it.
  void _openPendingLink() {
    final target = ref.read(pendingLinkProvider);
    if (target == null) return;
    if (ref.read(authControllerProvider).value is! SignedIn) return;
    ref.read(pendingLinkProvider.notifier).clear();
    ref.read(routerProvider).go(target.location);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(currentSettingsProvider);
    ref.listen(pendingLinkProvider, (_, _) => _openPendingLink());
    ref.listen(authControllerProvider, (_, _) => _openPendingLink());
    return MaterialApp.router(
      title: 'GitScholar',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      locale: settings.locale == null ? null : Locale(settings.locale!),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
