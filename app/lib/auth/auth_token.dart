import 'dart:convert';

/// Decodifica o payload de um JWT sem validar assinatura.
///
/// Ler claim de token sem verificar assinatura serve para diagnóstico e para
/// decidir se vale a pena tentar usar o token — nunca como controle de acesso.
/// Quem valida de verdade é o recurso (aqui, a API do Azure DevOps).
Map<String, dynamic>? decodeJwtPayload(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final map = jsonDecode(decoded);
    return map is Map<String, dynamic> ? map : null;
  } catch (_) {
    return null;
  }
}

class AuthAccount {
  const AuthAccount({
    required this.name,
    required this.username,
    required this.tenantId,
    required this.homeAccountId,
  });

  final String name;
  final String username;
  final String tenantId;
  final String homeAccountId;

  factory AuthAccount.fromJson(Map<String, dynamic> json) => AuthAccount(
        name: (json['name'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        tenantId: (json['tenantId'] as String?) ?? '',
        homeAccountId: (json['homeAccountId'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'username': username,
        'tenantId': tenantId,
        'homeAccountId': homeAccountId,
      };
}

class AuthToken {
  const AuthToken({
    required this.accessToken,
    this.idToken,
    this.expiresOn,
    this.scopes = const [],
    this.account,
  });

  final String accessToken;
  final String? idToken;
  final DateTime? expiresOn;
  final List<String> scopes;
  final AuthAccount? account;

  factory AuthToken.fromJson(Map<String, dynamic> json) {
    final expires = json['expiresOn'];
    final scopes = json['scopes'];
    final account = json['account'];
    return AuthToken(
      accessToken: (json['accessToken'] as String?) ?? '',
      idToken: json['idToken'] as String?,
      expiresOn: expires is String ? DateTime.tryParse(expires)?.toLocal() : null,
      scopes: scopes is List ? scopes.map((e) => '$e').toList() : const [],
      account: account is Map<String, dynamic>
          ? AuthAccount.fromJson(account)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'idToken': idToken,
        'expiresOn': expiresOn?.toUtc().toIso8601String(),
        'scopes': scopes,
        'account': account?.toJson(),
      };

  /// O token que o lado nativo de fato confere.
  ///
  /// Em modo identidade (B2C pedindo só `openid`) não vem access token de
  /// recurso, e o que atravessou a ponte foi o ID token. Conferir um campo
  /// vazio daria "não é JWT" e esconderia o token que realmente chegou.
  String get subjectToken =>
      accessToken.isNotEmpty ? accessToken : (idToken ?? '');

  bool get isIdentityOnly => accessToken.isEmpty && (idToken ?? '').isNotEmpty;

  Map<String, dynamic> get claims => decodeJwtPayload(subjectToken) ?? const {};

  String? get audience => claims['aud'] as String?;
  String? get issuer => claims['iss'] as String?;
  String? get tenantId => claims['tid'] as String?;
  String? get appId => claims['appid'] as String?;

  /// User flow que emitiu o token, em B2C.
  ///
  /// Só `tfp`. Já tratei `acr` como equivalente e era erro: em token de
  /// workforce o `acr` é o nível de autenticação — costuma vir `"1"` — e o app
  /// exibia "User flow que emitiu: 1" num tenant que não tem user flow nenhum.
  String? get policy => claims['tfp'] as String?;

  /// Claims do ID token, quando ele veio junto com um access token.
  ///
  /// Num tenant de workforce, pedir só `openid`/`profile` ainda devolve um
  /// access token — do Microsoft Graph, `aud` `00000003-0000-0000-c000-…`.
  /// Então há dois tokens com audiences diferentes, e ver os dois evita
  /// concluir que "a audience está errada" quando ela é só a do outro token.
  Map<String, dynamic> get idTokenClaims {
    final raw = idToken;
    if (raw == null || raw.isEmpty) return const {};
    return decodeJwtPayload(raw) ?? const {};
  }

  /// `exp` do próprio token, que é a fonte da verdade — `expiresOn` vem da SPA
  /// e é só o que o MSAL calculou.
  DateTime? get expiresFromClaims {
    final exp = claims['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
        .toLocal();
  }

  DateTime? get effectiveExpiry => expiresFromClaims ?? expiresOn;

  bool get isExpired {
    final expiry = effectiveExpiry;
    if (expiry == null) return false;
    return DateTime.now().isAfter(expiry);
  }

  /// Só para exibir na tela sem despejar o token inteiro no log.
  String get preview {
    final t = subjectToken;
    if (t.length <= 24) return t;
    return '${t.substring(0, 12)}…${t.substring(t.length - 8)}';
  }
}
