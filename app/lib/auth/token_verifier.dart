import '../config.dart';
import 'auth_token.dart';

class VerificationIssue {
  const VerificationIssue(this.label, this.detail, {this.fatal = true});

  final String label;
  final String detail;
  final bool fatal;
}

class VerificationResult {
  const VerificationResult(this.checks, this.issues);

  /// Checagens que passaram, em ordem, para mostrar na tela da POC.
  final List<String> checks;
  final List<VerificationIssue> issues;

  bool get ok => issues.where((i) => i.fatal).isEmpty;
}

/// Conferência mínima que o lado nativo faz antes de aceitar um token vindo
/// da WebView.
///
/// Isto **não** é validação de token: não há verificação de assinatura contra
/// o JWKS do emissor, e sem isso um token forjado passa por aqui. A verificação
/// de assinatura pertence a quem consome o token — a API de destino faz a dela.
/// O que estas checagens pegam é o caso realista: token do tenant errado, do
/// recurso errado, já expirado, ou um payload que não é JWT nenhum.
class TokenVerifier {
  const TokenVerifier._();

  /// Emissores aceitos, por sufixo de host: workforce, B2C e External ID.
  static const Set<String> _issuerHosts = {
    'sts.windows.net',
    'login.microsoftonline.com',
    'b2clogin.com',
    'ciamlogin.com',
  };

  /// [expectedAudiences] permite injetar as audiences aceitas; omitido, usa as
  /// de [AppConfig]. Existe para o teste poder exercitar o caso B2C, onde a
  /// audience é o client id — o valor de `AppConfig` é `const` e não dá para
  /// variar dentro de um teste.
  static VerificationResult verify(
    AuthToken token, {
    List<String>? expectedAudiences,
  }) {
    final checks = <String>[];
    final issues = <VerificationIssue>[];

    if (token.subjectToken.isEmpty) {
      issues.add(const VerificationIssue(
        'token',
        'A SPA mandou um payload sem access token nem ID token.',
      ));
      return VerificationResult(checks, issues);
    }

    if (token.isIdentityOnly) {
      checks.add('Modo identidade: conferindo o ID token');
    }

    final claims = token.claims;
    if (claims.isEmpty) {
      issues.add(const VerificationIssue(
        'formato',
        'O token não é um JWT legível em três partes.',
      ));
      return VerificationResult(checks, issues);
    }
    checks.add('É um JWT com payload decodificável');

    final aud = token.audience;
    final expected = expectedAudiences ?? AppConfig.expectedAudiences;
    if (aud == null) {
      issues.add(const VerificationIssue('aud', 'Token sem claim `aud`.'));
    } else if (!expected.contains(aud)) {
      issues.add(VerificationIssue(
        'aud',
        'Audience é `$aud`, esperado ${expected.join(' ou ')}. '
            'Ajuste com --dart-define=EXPECTED_AUDIENCE=$aud se esta audience '
            'for a correta para o seu IdP.',
      ));
    } else {
      checks.add('Audience confere: $aud');
    }

    final tid = token.tenantId;
    if (AppConfig.expectedTenantId.isNotEmpty) {
      if (tid != AppConfig.expectedTenantId) {
        issues.add(VerificationIssue(
          'tid',
          'Token emitido pelo tenant `$tid`, esperado '
              '`${AppConfig.expectedTenantId}`.',
        ));
      } else {
        checks.add('Tenant confere com o configurado');
      }
    } else if (tid != null) {
      checks.add('Tenant do token: $tid (checagem desligada)');
    }

    final iss = token.issuer;
    final issHost = iss == null ? null : Uri.tryParse(iss)?.host.toLowerCase();
    final issuerOk = issHost != null &&
        _issuerHosts.any((h) => issHost == h || issHost.endsWith('.$h'));
    if (!issuerOk) {
      issues.add(VerificationIssue('iss', 'Issuer inesperado: `$iss`.'));
    } else {
      checks.add('Issuer é um endpoint de identidade da Microsoft');
    }

    final policy = token.policy;
    if (policy != null) {
      checks.add('User flow que emitiu: $policy');
    }

    final expiry = token.effectiveExpiry;
    if (expiry == null) {
      issues.add(const VerificationIssue(
        'exp',
        'Token sem claim `exp`.',
        fatal: false,
      ));
    } else if (DateTime.now().isAfter(expiry)) {
      issues.add(VerificationIssue('exp', 'Token já expirou em $expiry.'));
    } else {
      checks.add('Válido até $expiry');
    }

    return VerificationResult(checks, issues);
  }
}
