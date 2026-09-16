import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/infrastructure/local/secure_store.dart';
import 'package:gitscholar/presentation/core/providers.dart';
import 'package:scholar_agent/scholar_agent.dart';

/// Choosing between Anthropic and OpenAI-compatible providers (ADR-0010).
void main() {
  group('buildLlmClient', () {
    test('anthropic is the default', () {
      final client = buildLlmClient(provider: 'anthropic', apiKey: 'k');
      expect(client, isA<AnthropicClient>());
      expect(
        buildLlmClient(provider: 'unknown', apiKey: 'k'),
        isA<AnthropicClient>(),
      );
    });

    test('openai and openrouter use their own endpoints', () {
      final openAi =
          buildLlmClient(provider: 'openai', apiKey: 'k') as OpenAiClient;
      expect(openAi.baseUrl, OpenAiClient.openAiBaseUrl);
      expect(openAi.extraHeaders, isEmpty);

      final router =
          buildLlmClient(provider: 'openrouter', apiKey: 'k') as OpenAiClient;
      expect(router.baseUrl, OpenAiClient.openRouterBaseUrl);
      expect(router.extraHeaders, containsPair('X-Title', 'GitScholar'));
    });

    test('a custom endpoint is used when given, otherwise the default', () {
      final custom =
          buildLlmClient(
                provider: 'custom',
                apiKey: 'k',
                baseUrl: 'https://llm.lab.internal/v1',
              )
              as OpenAiClient;
      expect(custom.baseUrl, 'https://llm.lab.internal/v1');

      final blank =
          buildLlmClient(provider: 'custom', apiKey: 'k', baseUrl: '  ')
              as OpenAiClient;
      expect(blank.baseUrl, OpenAiClient.openAiBaseUrl);

      final overridden =
          buildLlmClient(
                provider: 'openrouter',
                apiKey: 'k',
                baseUrl: 'https://proxy/v1',
              )
              as OpenAiClient;
      expect(overridden.baseUrl, 'https://proxy/v1');
    });
  });

  test('each provider keeps its own API key', () {
    expect(SecureStore.apiKeyFor('anthropic'), 'anthropic_api_key');
    expect(SecureStore.apiKeyFor('openai'), 'openai_api_key');
    expect(SecureStore.apiKeyFor('openrouter'), 'openrouter_api_key');
    expect(SecureStore.apiKeyFor('custom'), 'custom_llm_api_key');
    expect(SecureStore.apiKeyFor('anything else'), SecureStore.anthropicKey);
  });

  test('model choices are fixed for Anthropic and free text elsewhere', () {
    expect(modelChoicesFor('anthropic'), ClaudeModels.all);
    expect(modelChoicesFor('openai'), isEmpty);
    expect(defaultModelFor('anthropic'), ClaudeModels.opus5);
    expect(defaultModelFor('openrouter'), isEmpty);
  });

  test('settings keep the provider and base URL', () {
    const s = Settings();
    expect(s.aiProvider, 'anthropic');
    expect(s.aiBaseUrl, isNull);
    final switched = s.copyWith(
      aiProvider: 'openrouter',
      aiBaseUrl: 'https://proxy/v1',
      aiModel: 'vendor/model',
    );
    final restored = Settings.fromJson(switched.toJson());
    expect(restored.aiProvider, 'openrouter');
    expect(restored.aiBaseUrl, 'https://proxy/v1');
    expect(restored.aiModel, 'vendor/model');
    expect(restored.copyWith(clearAiBaseUrl: true).aiBaseUrl, isNull);
  });
}
