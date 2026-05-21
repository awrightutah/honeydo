import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'rate_limit_service.dart';

/// Centralized API service with rate limiting, retry logic, and error handling.
class ApiService {
  ApiService._();
  static final ApiService instance = ApiService._();

  final _supabase = Supabase.instance.client;

  // Rate limiters for different operation types
  final RateLimiter _readLimiter = RateLimiter(
    maxCalls: 60,
    window: const Duration(minutes: 1),
  );
  final RateLimiter _writeLimiter = RateLimiter(
    maxCalls: 30,
    window: const Duration(minutes: 1),
  );
  final RateLimiter _authLimiter = RateLimiter(
    maxCalls: 10,
    window: const Duration(minutes: 1),
  );

  // Throttlers for UI actions
  final Throttler _uiActionThrottler = Throttler(
    interval: const Duration(milliseconds: 500),
  );
  final Throttler _searchThrottler = Throttler(
    interval: const Duration(milliseconds: 300),
  );

  // Debouncers for input fields
  final Debouncer _searchDebouncer = Debouncer(
    delay: const Duration(milliseconds: 300),
  );
  final Debouncer _inputDebouncer = Debouncer(
    delay: const Duration(milliseconds: 500),
  );

  /// Execute a function with retry logic.
  Future<T> _withRetry<T>(
    Future<T> Function() fn, {
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    int attempts = 0;
    while (true) {
      attempts++;
      try {
        return await fn();
      } catch (e) {
        if (attempts >= maxRetries) rethrow;
        // Don't retry on client errors (4xx)
        if (e is PostgrestException && e.code != null && e.code!.startsWith('4')) {
          rethrow;
        }
        await Future.delayed(retryDelay * attempts);
      }
    }
  }

  /// Query a table with rate limiting and retry.
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? select,
    Map<String, dynamic>? filters,
    String? orderBy,
    bool ascending = true,
    int? limit,
    int maxRetries = 2,
  }) async {
    return _withRetry(() async {
      await _readLimiter.waitAndRun(() async {});
      var query = _supabase.from(table).select(select ?? '*');
      if (filters != null) {
        for (final entry in filters.entries) {
          query = query.eq(entry.key, entry.value);
        }
      }
      dynamic resultQuery = query;
      if (orderBy != null) {
        resultQuery = resultQuery.order(orderBy, ascending: ascending);
      }
      if (limit != null) {
        resultQuery = resultQuery.limit(limit);
      }
      final result = await resultQuery;
      return List<Map<String, dynamic>>.from(result);
    }, maxRetries: maxRetries);
  }

  /// Insert a row with rate limiting and retry.
  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> data, {
    int maxRetries = 2,
  }) async {
    return _withRetry(() async {
      await _writeLimiter.waitAndRun(() async {});
      final result = await _supabase.from(table).insert(data).select().single();
      return result;
    }, maxRetries: maxRetries);
  }

  /// Update rows with rate limiting and retry.
  Future<List<Map<String, dynamic>>> update(
    String table,
    Map<String, dynamic> data, {
    required String column,
    required dynamic value,
    int maxRetries = 2,
  }) async {
    return _withRetry(() async {
      await _writeLimiter.waitAndRun(() async {});
      final result = await _supabase.from(table).update(data).eq(column, value).select();
      return List<Map<String, dynamic>>.from(result);
    }, maxRetries: maxRetries);
  }

  /// Delete rows with rate limiting and retry.
  Future<void> delete(
    String table, {
    required String column,
    required dynamic value,
    int maxRetries = 2,
  }) async {
    return _withRetry(() async {
      await _writeLimiter.waitAndRun(() async {});
      await _supabase.from(table).delete().eq(column, value);
    }, maxRetries: maxRetries);
  }

  /// Execute a raw SQL query with rate limiting.
  Future<List<Map<String, dynamic>>> rpc(
    String functionName, {
    Map<String, dynamic>? params,
    int maxRetries = 2,
  }) async {
    return _withRetry(() async {
      await _readLimiter.waitAndRun(() async {});
      final result = await _supabase.rpc(functionName, params: params);
      if (result is List) {
        return List<Map<String, dynamic>>.from(result);
      }
      return [];
    }, maxRetries: maxRetries);
  }

  /// Throttle a UI action (e.g., button clicks).
  void throttleUiAction(VoidCallback action) {
    _uiActionThrottler.run(action);
  }

  /// Throttle a search operation.
  Future<T?> throttleSearch<T>(Future<T> Function() searchFn) async {
    return _searchThrottler.runAsync(searchFn);
  }

  /// Debounce a search input.
  Future<T?> debounceSearch<T>(Future<T> Function() searchFn) {
    return _searchDebouncer.runAsync(searchFn);
  }

  /// Debounce a text input field.
  Future<T?> debounceInput<T>(Future<T> Function() inputFn) {
    return _inputDebouncer.runAsync(inputFn);
  }

  /// Get the current rate limit status.
  Map<String, dynamic> getRateLimitStatus() {
    return {
      'read': {
        'remaining': _readLimiter.remainingCalls,
        'max': _readLimiter.maxCalls,
        'window': _readLimiter.window.inSeconds,
      },
      'write': {
        'remaining': _writeLimiter.remainingCalls,
        'max': _writeLimiter.maxCalls,
        'window': _writeLimiter.window.inSeconds,
      },
      'auth': {
        'remaining': _authLimiter.remainingCalls,
        'max': _authLimiter.maxCalls,
        'window': _authLimiter.window.inSeconds,
      },
    };
  }

  /// Reset all rate limiters (useful for testing).
  void resetRateLimiters() {
    _readLimiter.reset();
    _writeLimiter.reset();
    _authLimiter.reset();
  }

  void dispose() {
    _searchDebouncer.dispose();
    _inputDebouncer.dispose();
  }
}