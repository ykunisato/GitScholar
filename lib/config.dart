/// Build-time configuration.
abstract final class AppConfig {
  /// GitHub OAuth App client id (Device Flow enabled). Not a secret.
  /// Override with `--dart-define=GITHUB_CLIENT_ID=...`.
  static const githubClientId = String.fromEnvironment('GITHUB_CLIENT_ID');

  /// Whether a client id has been configured.
  static bool get hasGitHubClientId => githubClientId.isNotEmpty;
}
