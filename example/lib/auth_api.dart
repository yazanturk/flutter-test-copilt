import 'dart:async';

class NetworkException implements Exception {
  @override
  String toString() => 'Network error';
}

class SessionExpiredException implements Exception {}

class InvalidCredentialsException implements Exception {}

class Product {
  const Product(this.id, this.name, this.priceCents);
  final int id;
  final String name;
  final int priceCents;
}

/// The app's only backend boundary. Tests inject [FakeAuthApi]; nothing in
/// this sample talks to a real server.
abstract class AuthApi {
  Future<String> login(String email, String password);
  Future<List<Product>> products(String token);
}

/// Deterministic in-memory backend with failure injection.
class FakeAuthApi implements AuthApi {
  FakeAuthApi({
    this.latency = const Duration(milliseconds: 400),
    this.failNextLogins = 0,
    this.expireAfterRequests,
  });

  static const validEmail = 'test@example.com';
  static const validPassword = 'secret123';

  final Duration latency;

  /// Number of upcoming login calls that fail with [NetworkException].
  int failNextLogins;

  /// When set, product requests fail with [SessionExpiredException] after
  /// this many successful ones.
  int? expireAfterRequests;

  int loginCalls = 0;
  int _productRequests = 0;

  @override
  Future<String> login(String email, String password) async {
    loginCalls++;
    await Future<void>.delayed(latency);
    if (failNextLogins > 0) {
      failNextLogins--;
      throw NetworkException();
    }
    if (email != validEmail || password != validPassword) throw InvalidCredentialsException();
    return 'token-${DateTime.now().microsecondsSinceEpoch}';
  }

  @override
  Future<List<Product>> products(String token) async {
    await Future<void>.delayed(latency);
    if (expireAfterRequests != null && _productRequests >= expireAfterRequests!) {
      throw SessionExpiredException();
    }
    _productRequests++;
    return List.generate(100, (i) => Product(i + 1, 'Product ${i + 1}', 100 * (i + 1)));
  }
}
