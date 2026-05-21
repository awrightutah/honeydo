import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Service providing offline support with local caching and connectivity awareness.
/// Caches frequently accessed data locally and syncs when connectivity is restored.
class OfflineService {
  OfflineService._();
  static final OfflineService instance = OfflineService._();

  static const _cachePrefix = 'offline_cache_';
  static const _pendingOpsKey = 'pending_operations';
  static const _lastSyncKey = 'last_sync_timestamp';

  final ValueNotifier<bool> isOnline = ValueNotifier(true);
  final ValueNotifier<int> pendingOperationsCount = ValueNotifier(0);

  SharedPreferences? _prefs;
  Connectivity? _connectivity;

  /// Initialize the offline service with connectivity monitoring
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _connectivity = Connectivity();

    // Check initial connectivity
    final result = await _connectivity!.checkConnectivity();
    isOnline.value = !result.contains(ConnectivityResult.none);

    // Listen for connectivity changes
    _connectivity!.onConnectivityChanged.listen((result) {
      final wasOffline = !isOnline.value;
      isOnline.value = !result.contains(ConnectivityResult.none);

      // If we just came back online, sync pending operations
      if (wasOffline && isOnline.value) {
        syncPendingOperations();
      }
    });

    // Load pending operations count
    _updatePendingCount();
  }

  /// Check if the device currently has connectivity
  Future<bool> checkConnectivity() async {
    try {
      if (_connectivity == null) {
        _connectivity = Connectivity();
      }
      final result = await _connectivity!.checkConnectivity();
      isOnline.value = !result.contains(ConnectivityResult.none);
      return isOnline.value;
    } catch (_) {
      return true; // Assume online if we can't check
    }
  }

  /// Cache data locally with a timestamp
  Future<void> cacheData(String key, Map<String, dynamic> data) async {
    if (_prefs == null) return;
    final wrapper = {
      'data': data,
      'cached_at': DateTime.now().toIso8601String(),
    };
    await _prefs!.setString('$_cachePrefix$key', jsonEncode(wrapper));
  }

  /// Cache a list of data locally
  Future<void> cacheList(String key, List<Map<String, dynamic>> data) async {
    if (_prefs == null) return;
    final wrapper = {
      'data': data,
      'cached_at': DateTime.now().toIso8601String(),
    };
    await _prefs!.setString('$_cachePrefix$key', jsonEncode(wrapper));
  }

  /// Retrieve cached data
  Map<String, dynamic>? getCachedData(String key) {
    if (_prefs == null) return null;
    final raw = _prefs!.getString('$_cachePrefix$key');
    if (raw == null) return null;
    try {
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      return wrapper['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// Retrieve cached list data
  List<Map<String, dynamic>>? getCachedList(String key) {
    if (_prefs == null) return null;
    final raw = _prefs!.getString('$_cachePrefix$key');
    if (raw == null) return null;
    try {
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final data = wrapper['data'];
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Get the timestamp when data was cached
  DateTime? getCachedAt(String key) {
    if (_prefs == null) return null;
    final raw = _prefs!.getString('$_cachePrefix$key');
    if (raw == null) return null;
    try {
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = wrapper['cached_at'] as String?;
      return cachedAt != null ? DateTime.tryParse(cachedAt) : null;
    } catch (_) {
      return null;
    }
  }

  /// Check if cached data is stale (older than maxAge)
  bool isCacheStale(String key, {Duration maxAge = const Duration(minutes: 15)}) {
    final cachedAt = getCachedAt(key);
    if (cachedAt == null) return true;
    return DateTime.now().difference(cachedAt) > maxAge;
  }

  /// Fetch data with offline fallback: try online first, fall back to cache
  Future<Map<String, dynamic>?> fetchWithFallback(
    String key, {
    required Future<Map<String, dynamic>> Function() onlineFetch,
    Duration maxAge = const Duration(minutes: 15),
    bool forceRefresh = false,
  }) async {
    final online = await checkConnectivity();

    if (online && !forceRefresh && !isCacheStale(key, maxAge: maxAge)) {
      // Cache is fresh, use it
      return getCachedData(key);
    }

    if (online) {
      try {
        final data = await onlineFetch();
        await cacheData(key, data);
        return data;
      } catch (_) {
        // Online fetch failed, fall back to cache
        return getCachedData(key);
      }
    }

    // Offline: use cache
    return getCachedData(key);
  }

  /// Fetch a list with offline fallback
  Future<List<Map<String, dynamic>>> fetchListWithFallback(
    String key, {
    required Future<List<Map<String, dynamic>>> Function() onlineFetch,
    Duration maxAge = const Duration(minutes: 15),
    bool forceRefresh = false,
  }) async {
    final online = await checkConnectivity();

    if (online && !forceRefresh && !isCacheStale(key, maxAge: maxAge)) {
      return getCachedList(key) ?? [];
    }

    if (online) {
      try {
        final data = await onlineFetch();
        await cacheList(key, data);
        return data;
      } catch (_) {
        return getCachedList(key) ?? [];
      }
    }

    return getCachedList(key) ?? [];
  }

  /// Queue a write operation for later sync when offline
  Future<void> queueOperation({
    required String table,
    required String operation, // 'insert', 'update', 'delete'
    required Map<String, dynamic> data,
    String? recordId,
  }) async {
    if (_prefs == null) return;

    final ops = _getPendingOperations();
    ops.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'table': table,
      'operation': operation,
      'data': data,
      'record_id': recordId,
      'queued_at': DateTime.now().toIso8601String(),
      'attempts': 0,
    });

    await _prefs!.setString(_pendingOpsKey, jsonEncode(ops));
    _updatePendingCount();
  }

  /// Sync all pending operations when back online
  Future<SyncResult> syncPendingOperations() async {
    final ops = _getPendingOperations();
    if (ops.isEmpty) {
      return SyncResult(success: 0, failed: 0, remaining: 0);
    }

    final online = await checkConnectivity();
    if (!online) {
      return SyncResult(success: 0, failed: 0, remaining: ops.length);
    }

    int success = 0;
    int failed = 0;
    final remaining = <Map<String, dynamic>>[];
    final client = Supabase.instance.client;

    for (final op in ops) {
      try {
        final table = op['table'] as String;
        final operation = op['operation'] as String;
        final data = Map<String, dynamic>.from(op['data'] as Map);
        final recordId = op['record_id'] as String?;

        switch (operation) {
          case 'insert':
            await client.from(table).insert(data);
            break;
          case 'update':
            if (recordId != null) {
              await client.from(table).update(data).eq('id', recordId);
            }
            break;
          case 'delete':
            if (recordId != null) {
              await client.from(table).delete().eq('id', recordId);
            }
            break;
        }
        success++;
      } catch (_) {
        final attempts = (op['attempts'] as int? ?? 0) + 1;
        if (attempts < 5) {
          op['attempts'] = attempts;
          remaining.add(op);
          failed++;
        }
        // If attempted 5 times, drop the operation
      }
    }

    await _prefs!.setString(_pendingOpsKey, jsonEncode(remaining));
    _updatePendingCount();

    if (success > 0) {
      await _prefs!.setString(_lastSyncKey, DateTime.now().toIso8601String());
    }

    return SyncResult(success: success, failed: failed, remaining: remaining.length);
  }

  /// Get the last sync timestamp
  DateTime? getLastSyncTime() {
    if (_prefs == null) return null;
    final raw = _prefs!.getString(_lastSyncKey);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    if (_prefs == null) return;
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_cachePrefix));
    for (final key in keys) {
      await _prefs!.remove(key);
    }
  }

  /// Clear pending operations (use with caution)
  Future<void> clearPendingOperations() async {
    if (_prefs == null) return;
    await _prefs!.remove(_pendingOpsKey);
    _updatePendingCount();
  }

  /// Perform an online write, queuing if offline
  Future<void> performWrite({
    required String table,
    required String operation,
    required Map<String, dynamic> data,
    String? recordId,
    Duration maxAge = const Duration(minutes: 15),
    String? cacheKey,
  }) async {
    final online = await checkConnectivity();

    if (online) {
      try {
        final client = Supabase.instance.client;
        switch (operation) {
          case 'insert':
            await client.from(table).insert(data);
            break;
          case 'update':
            if (recordId != null) {
              await client.from(table).update(data).eq('id', recordId);
            }
            break;
          case 'delete':
            if (recordId != null) {
              await client.from(table).delete().eq('id', recordId);
            }
            break;
        }

        // Update cache if cacheKey provided
        if (cacheKey != null) {
          // Invalidate cache so next read refreshes
          await _prefs?.remove('$_cachePrefix$cacheKey');
        }
        return;
      } catch (_) {
        // Online write failed, queue for later
      }
    }

    // Queue operation for later sync
    await queueOperation(
      table: table,
      operation: operation,
      data: data,
      recordId: recordId,
    );

    // Optimistically update cache if cacheKey provided
    if (cacheKey != null && _prefs != null) {
      // Mark cache as stale so it refreshes on next read
      final cached = getCachedList(cacheKey);
      if (cached != null && operation == 'insert') {
        cached.add(data);
        await cacheList(cacheKey, cached);
      }
    }
  }

  // Private helpers

  List<Map<String, dynamic>> _getPendingOperations() {
    if (_prefs == null) return [];
    final raw = _prefs!.getString(_pendingOpsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  void _updatePendingCount() {
    final ops = _getPendingOperations();
    pendingOperationsCount.value = ops.length;
  }
}

/// Result of a sync operation
class SyncResult {
  final int success;
  final int failed;
  final int remaining;

  const SyncResult({
    required this.success,
    required this.failed,
    required this.remaining,
  });

  @override
  String toString() => 'SyncResult(success: $success, failed: $failed, remaining: $remaining)';
}
