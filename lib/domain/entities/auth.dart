/// Signed-in GitHub user.
class GitHubUser {
  const GitHubUser({
    required this.login,
    required this.id,
    required this.avatarUrl,
    this.name,
  });

  final String login;
  final int id;
  final String avatarUrl;
  final String? name;
}

/// Authentication state (docs/03_data_model.md §1.1).
sealed class AuthState {
  const AuthState();
}

class SignedOut extends AuthState {
  const SignedOut();
}

class PendingDeviceCode extends AuthState {
  const PendingDeviceCode({
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
  });

  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
}

class SignedIn extends AuthState {
  const SignedIn(this.user);

  final GitHubUser user;
}
