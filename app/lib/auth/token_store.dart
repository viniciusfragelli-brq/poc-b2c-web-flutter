import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_token.dart';

/// Guarda o token no Keychain (iOS) / EncryptedSharedPreferences (Android).
///
/// O token nunca volta para a WebView: quem precisar dele é o código nativo.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // O default do plugin 11.x já é AES-GCM com chave embrulhada por
              // RSA no KeyStore — não há mais o flag encryptedSharedPreferences.
              aOptions: AndroidOptions(),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _key = 'poc_login.ado_token';

  final FlutterSecureStorage _storage;

  Future<void> save(AuthToken token) =>
      _storage.write(key: _key, value: jsonEncode(token.toJson()));

  Future<AuthToken?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return AuthToken.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _key);
}
