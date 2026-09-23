import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:poc_login/auth/auth_token.dart';
import 'package:poc_login/auth/bridge_message.dart';
import 'package:poc_login/auth/token_verifier.dart';
import 'package:poc_login/config.dart';

/// JWT com assinatura deliberadamente inválida.
///
/// Serve para exercitar a conferência de claims — e para deixar registrado que
/// ela passa num token forjado. É exatamente por isso que ela não é validação.
String fakeJwt(Map<String, dynamic> claims) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none', 'typ': 'JWT'})}.${seg(claims)}.nao-assinado';
}

Map<String, dynamic> adoClaims({
  String? aud,
  String tid = '11111111-1111-1111-1111-111111111111',
  String iss = 'https://sts.windows.net/11111111-1111-1111-1111-111111111111/',
  Duration ttl = const Duration(hours: 1),
}) =>
    {
      'aud': aud ?? AppConfig.adoResourceId,
      'iss': iss,
      'tid': tid,
      'appid': '22222222-2222-2222-2222-222222222222',
      'exp': DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000,
    };

void main() {
  group('BridgeMessage', () {
    test('lê o envelope completo', () {
      final msg = BridgeMessage.parse(
        '{"type":"auth_success","nonce":"abc","payload":{"accessToken":"x"}}',
      );
      expect(msg.type, BridgeMessageType.authSuccess);
      expect(msg.nonce, 'abc');
      expect(msg.payload['accessToken'], 'x');
    });

    test('lixo no canal não estoura nem vira sucesso', () {
      final msg = BridgeMessage.parse('nao sou json');
      expect(msg.type, BridgeMessageType.unknown);
      expect(msg.nonce, isNull);
    });

    test('tipo desconhecido nunca é interpretado como authSuccess', () {
      expect(
        BridgeMessage.parse('{"type":"qualquer","nonce":"a"}').type,
        BridgeMessageType.unknown,
      );
    });

    test('payload que não é objeto não quebra o parse', () {
      final msg = BridgeMessage.parse('{"type":"auth_success","payload":42}');
      expect(msg.payload, isEmpty);
    });
  });

  group('AuthToken', () {
    test('expiração vem do claim exp, não do que a SPA informou', () {
      final token = AuthToken(
        accessToken: fakeJwt(adoClaims(ttl: const Duration(hours: 2))),
        // A SPA mentiu dizendo que já expirou; o claim manda.
        expiresOn: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(token.isExpired, isFalse);
      expect(token.effectiveExpiry!.isAfter(DateTime.now()), isTrue);
    });

    test('token sem três partes não produz claims', () {
      const token = AuthToken(accessToken: 'abc.def');
      expect(token.claims, isEmpty);
      expect(token.audience, isNull);
    });
  });

  group('TokenVerifier — B2C e modo identidade', () {
    test('confere o ID token quando não veio access token', () {
      final token = AuthToken(
        accessToken: '',
        idToken: fakeJwt(adoClaims()),
      );
      expect(token.isIdentityOnly, isTrue);
      final result = TokenVerifier.verify(token);
      expect(result.ok, isTrue);
      expect(result.checks.first, contains('Modo identidade'));
    });

    test('aceita issuer do B2C e reporta o user flow', () {
      final token = AuthToken(
        accessToken: fakeJwt({
          ...adoClaims(
            iss: 'https://contoso.b2clogin.com/33333333-3333-3333-3333-333333333333/v2.0/',
          ),
          'tfp': 'B2C_1_susi',
        }),
      );
      final result = TokenVerifier.verify(token);
      expect(result.issues.map((i) => i.label), isNot(contains('iss')));
      expect(result.checks, contains('User flow que emitiu: B2C_1_susi'));
    });

    test('aceita ID token de B2C com a audience do client id', () {
      const clientId = '55555555-5555-5555-5555-555555555555';
      final token = AuthToken(
        accessToken: '',
        idToken: fakeJwt({
          'aud': clientId,
          'iss':
              'https://contoso.b2clogin.com/33333333-3333-3333-3333-333333333333/v2.0/',
          'tid': '33333333-3333-3333-3333-333333333333',
          'tfp': 'B2C_1_susi',
          'exp': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
      );
      final result =
          TokenVerifier.verify(token, expectedAudiences: const [clientId]);
      expect(result.ok, isTrue, reason: result.issues.map((i) => i.detail).join('; '));
      expect(result.checks, contains('Audience confere: $clientId'));
      expect(result.checks, contains('User flow que emitiu: B2C_1_susi'));
    });

    test('a mensagem de audience errada diz qual dart-define usar', () {
      final result = TokenVerifier.verify(
        AuthToken(accessToken: fakeJwt(adoClaims(aud: 'audience-inesperada'))),
      );
      final issue = result.issues.firstWhere((i) => i.label == 'aud');
      expect(issue.detail, contains('EXPECTED_AUDIENCE=audience-inesperada'));
    });

    test('acr de token workforce não é confundido com user flow do B2C', () {
      final token = AuthToken(
        accessToken: fakeJwt({...adoClaims(), 'acr': '1'}),
      );
      expect(token.policy, isNull);
      final result = TokenVerifier.verify(token);
      expect(
        result.checks.where((c) => c.contains('User flow')),
        isEmpty,
        reason: 'acr="1" em tenant de workforce não é user flow',
      );
    });

    test('expõe as audiences dos dois tokens quando ambos vêm', () {
      const graph = '00000003-0000-0000-c000-000000000000';
      const clientId = '55555555-5555-5555-5555-555555555555';
      final token = AuthToken(
        accessToken: fakeJwt(adoClaims(aud: graph)),
        idToken: fakeJwt(adoClaims(aud: clientId)),
      );
      // O access token é o que vale como credencial, então é ele que a
      // verificação toma como assunto.
      expect(token.isIdentityOnly, isFalse);
      expect(token.audience, graph);
      expect(token.idTokenClaims['aud'], clientId);
    });

    test('aceita issuer do External ID', () {
      final result = TokenVerifier.verify(
        AuthToken(
          accessToken: fakeJwt(adoClaims(
            iss: 'https://contoso.ciamlogin.com/44444444-4444-4444-4444-444444444444/v2.0',
          )),
        ),
      );
      expect(result.issues.map((i) => i.label), isNot(contains('iss')));
    });

    test('payload totalmente vazio é reprovado', () {
      final result = TokenVerifier.verify(const AuthToken(accessToken: ''));
      expect(result.ok, isFalse);
      expect(result.issues.single.label, 'token');
    });
  });

  group('TokenVerifier', () {
    test('aprova um token com audience do Azure DevOps e exp no futuro', () {
      final result =
          TokenVerifier.verify(AuthToken(accessToken: fakeJwt(adoClaims())));
      expect(result.ok, isTrue);
      expect(result.checks, isNotEmpty);
    });

    test('reprova algo que não é JWT', () {
      final result =
          TokenVerifier.verify(const AuthToken(accessToken: 'nao-e-jwt'));
      expect(result.ok, isFalse);
      expect(result.issues.single.label, 'formato');
    });

    test('reprova token emitido para outro recurso', () {
      final result = TokenVerifier.verify(
        AuthToken(accessToken: fakeJwt(adoClaims(aud: '00000003-0000-0000-c000-000000000000'))),
      );
      expect(result.ok, isFalse);
      expect(result.issues.map((i) => i.label), contains('aud'));
    });

    test('reprova token já expirado', () {
      final result = TokenVerifier.verify(
        AuthToken(accessToken: fakeJwt(adoClaims(ttl: const Duration(hours: -1)))),
      );
      expect(result.ok, isFalse);
      expect(result.issues.map((i) => i.label), contains('exp'));
    });

    test('reprova issuer que não é o STS da Microsoft', () {
      final result = TokenVerifier.verify(
        AuthToken(accessToken: fakeJwt(adoClaims(iss: 'https://idp-falso.example/'))),
      );
      expect(result.ok, isFalse);
      expect(result.issues.map((i) => i.label), contains('iss'));
    });
  });
}
