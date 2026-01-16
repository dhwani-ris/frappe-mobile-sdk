// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

class FrappeException implements Exception {
  final String message;
  final int? statusCode;

  FrappeException(this.message, [this.statusCode]);

  @override
  String toString() => 'FrappeException: $message (Status: $statusCode)';
}

class AuthException extends FrappeException {
  AuthException(String message, [int? statusCode]) : super(message, statusCode);

  @override
  String toString() => 'AuthException: $message (Status: $statusCode)';
}

class ApiException extends FrappeException {
  final dynamic details;
  ApiException(String message, [int? statusCode, this.details]) : super(message, statusCode);

  @override
  String toString() => 'ApiException: $message (Status: $statusCode) Details: $details';
}

class NetworkException extends FrappeException {
  NetworkException(String message, [int? statusCode]) : super(message, statusCode);

  @override
  String toString() => 'NetworkException: $message';
}

class ValidationException extends FrappeException {
  final Map<String, dynamic>? errors;
  ValidationException(String message, [this.errors]) : super(message, 417);

  @override
  String toString() => 'ValidationException: $message Errors: $errors';
}
