/// User settings (docs/03_data_model.md §1.6).
class Settings {
  const Settings({
    this.aiProvider = 'anthropic',
    this.aiBaseUrl,
    this.aiModel = 'claude-opus-5',
    this.aiEffort = 'high',
    this.aiShowThinkingSummary = true,
    this.logAiContent = false,
    this.themeMode = 'system',
    this.locale,
    this.jupyterBaseUrl,
    this.jupyterKernel = 'python3',
    this.autoRunCode = false,
    this.cacheLimitMb = 2048,
    this.editorFontSize = 14,
    this.wordWrap = false,
  });

  factory Settings.fromJson(Map<String, dynamic> j) {
    const d = Settings();
    return Settings(
      aiProvider: j['aiProvider'] as String? ?? d.aiProvider,
      aiBaseUrl: j['aiBaseUrl'] as String?,
      aiModel: j['aiModel'] as String? ?? d.aiModel,
      aiEffort: j['aiEffort'] as String? ?? d.aiEffort,
      aiShowThinkingSummary:
          j['aiShowThinkingSummary'] as bool? ?? d.aiShowThinkingSummary,
      logAiContent: j['logAiContent'] as bool? ?? d.logAiContent,
      themeMode: j['themeMode'] as String? ?? d.themeMode,
      locale: j['locale'] as String?,
      jupyterBaseUrl: j['jupyterBaseUrl'] as String?,
      jupyterKernel: j['jupyterKernel'] as String? ?? d.jupyterKernel,
      autoRunCode: j['autoRunCode'] as bool? ?? d.autoRunCode,
      cacheLimitMb: (j['cacheLimitMb'] as num?)?.toInt() ?? d.cacheLimitMb,
      editorFontSize:
          (j['editorFontSize'] as num?)?.toDouble() ?? d.editorFontSize,
      wordWrap: j['wordWrap'] as bool? ?? d.wordWrap,
    );
  }

  /// `anthropic`, `openai`, `openrouter` or `custom` (ADR-0010).
  final String aiProvider;

  /// Endpoint root for `custom`, or an override for the others.
  final String? aiBaseUrl;

  final String aiModel;
  final String aiEffort;
  final bool aiShowThinkingSummary;
  final bool logAiContent;

  /// `system`, `light` or `dark`.
  final String themeMode;

  /// `ja`, `en`, or null for the device locale.
  final String? locale;
  final String? jupyterBaseUrl;
  final String jupyterKernel;

  /// Run code tools without confirmation.
  final bool autoRunCode;
  final int cacheLimitMb;
  final double editorFontSize;
  final bool wordWrap;

  Map<String, dynamic> toJson() => {
    'aiProvider': aiProvider,
    'aiBaseUrl': aiBaseUrl,
    'aiModel': aiModel,
    'aiEffort': aiEffort,
    'aiShowThinkingSummary': aiShowThinkingSummary,
    'logAiContent': logAiContent,
    'themeMode': themeMode,
    'locale': locale,
    'jupyterBaseUrl': jupyterBaseUrl,
    'jupyterKernel': jupyterKernel,
    'autoRunCode': autoRunCode,
    'cacheLimitMb': cacheLimitMb,
    'editorFontSize': editorFontSize,
    'wordWrap': wordWrap,
  };

  Settings copyWith({
    String? aiProvider,
    String? aiBaseUrl,
    bool clearAiBaseUrl = false,
    String? aiModel,
    String? aiEffort,
    bool? aiShowThinkingSummary,
    bool? logAiContent,
    String? themeMode,
    String? locale,
    bool clearLocale = false,
    String? jupyterBaseUrl,
    bool clearJupyter = false,
    String? jupyterKernel,
    bool? autoRunCode,
    int? cacheLimitMb,
    double? editorFontSize,
    bool? wordWrap,
  }) => Settings(
    aiProvider: aiProvider ?? this.aiProvider,
    aiBaseUrl: clearAiBaseUrl ? null : (aiBaseUrl ?? this.aiBaseUrl),
    aiModel: aiModel ?? this.aiModel,
    aiEffort: aiEffort ?? this.aiEffort,
    aiShowThinkingSummary: aiShowThinkingSummary ?? this.aiShowThinkingSummary,
    logAiContent: logAiContent ?? this.logAiContent,
    themeMode: themeMode ?? this.themeMode,
    locale: clearLocale ? null : (locale ?? this.locale),
    jupyterBaseUrl: clearJupyter
        ? null
        : (jupyterBaseUrl ?? this.jupyterBaseUrl),
    jupyterKernel: jupyterKernel ?? this.jupyterKernel,
    autoRunCode: autoRunCode ?? this.autoRunCode,
    cacheLimitMb: cacheLimitMb ?? this.cacheLimitMb,
    editorFontSize: editorFontSize ?? this.editorFontSize,
    wordWrap: wordWrap ?? this.wordWrap,
  );
}
