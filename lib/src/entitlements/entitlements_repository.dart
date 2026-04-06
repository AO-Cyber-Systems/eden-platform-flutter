import 'dart:convert';
import 'package:http/http.dart' as http;

import 'entitlements_models.dart';

/// Repository for fetching entitlements data from Eden Biz.
abstract class EntitlementsRepository {
  /// Fetches the combined subscription + entitlements + feature flags state.
  Future<EntitlementsBootstrap> bootstrap(String accessToken, String companyId);
}

/// HTTP implementation of [EntitlementsRepository].
class HttpEntitlementsRepository implements EntitlementsRepository {
  final String baseUrl;
  final http.Client _client;

  HttpEntitlementsRepository({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<EntitlementsBootstrap> bootstrap(String accessToken, String companyId) async {
    final uri = Uri.parse('$baseUrl/api/v1/entitlements/bootstrap')
        .replace(queryParameters: {'company_id': companyId});

    final response = await _client.get(uri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    });

    if (response.statusCode >= 300) {
      throw EntitlementsException(
        'Bootstrap failed: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return EntitlementsBootstrap.fromJson(data);
  }
}

/// Exception thrown by [EntitlementsRepository].
class EntitlementsException implements Exception {
  final String message;
  final int? statusCode;

  EntitlementsException(this.message, {this.statusCode});

  @override
  String toString() => 'EntitlementsException: $message';
}
