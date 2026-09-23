import 'auth_token.dart';
import 'token_verifier.dart';

/// O que a tela de login devolve para quem a abriu.
class LoginOutcome {
  const LoginOutcome({
    this.token,
    this.verification,
    this.error,
    this.diagnostics = const [],
    this.rawPayload,
  });

  final AuthToken? token;
  final VerificationResult? verification;
  final String? error;
  final List<String> diagnostics;

  /// O JSON exato que a SPA empurrou pelo canal, indentado para leitura.
  final String? rawPayload;

  bool get succeeded => token != null && (verification?.ok ?? false);
}
