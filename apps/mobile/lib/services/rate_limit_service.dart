import 'dart:async';
import 'package:flutter/foundation.dart';

/// Debouncer — delays execution until the user stops triggering for [delay].
class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({this.delay = const Duration(milliseconds: 300)});

  /// Run [action] after [delay] since the last call.
  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Run an async [action] after [delay] since the last call.
  Future<T?> runAsync<T>(Future<T> Function() action) {
    _timer?.cancel();
    final completer = Completer<T?>();
    _timer = Timer(delay, () async {
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    });
    return completer.future;
  }

  /// Cancel any pending debounced action.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Whether a debounced action is currently pending.
  bool get isPending => _timer?.isActive ?? false;

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Async-specific debouncer that prevents overlapping calls.
class AsyncDebouncer {
  final Duration delay;
  Timer? _timer;
  bool _isRunning = false;

  AsyncDebouncer({this.delay = const Duration(milliseconds: 300)});

  /// Run [action] after [delay], skipping if already running.
  Future<T?> run<T>(Future<T> Function() action) async {
    if (_isRunning) return null;

    final completer = Completer<T?>();
    _timer?.cancel();
    _timer = Timer(delay, () async {
      _isRunning = true;
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        _isRunning = false;
      }
    });
    return completer.future;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Throttler — ensures [action] runs at most once per [interval].
class Throttler {
  final Duration interval;
  DateTime? _lastRun;

  Throttler({this.interval = const Duration(seconds: 1)});

  /// Run [action] if enough time has passed since the last call.
  void run(VoidCallback action) {
    final now = DateTime.now();
    if (_lastRun == null || now.difference(_lastRun!) >= interval) {
      _lastRun = now;
      action();
    }
  }

  /// Run an async [action] if enough time has passed since the last call.
  Future<T?> runAsync<T>(Future<T> Function() action) async {
    final now = DateTime.now();
    if (_lastRun == null || now.difference(_lastRun!) >= interval) {
      _lastRun = now;
      return action();
    }
    return null;
  }

  /// Whether the throttler is currently blocking (i.e., too soon to call again).
  bool get isThrottled {
    if (_lastRun == null) return false;
    return DateTime.now().difference(_lastRun!) < interval;
  }

  void reset() {
    _lastRun = null;
  }
}

/// Rate limiter — sliding window algorithm that allows at most [maxCalls] per [window].
class RateLimiter {
  final int maxCalls;
  final Duration window;
  final List<DateTime> _callTimestamps = [];

  RateLimiter({
    this.maxCalls = 30,
    this.window = const Duration(minutes: 1),
  });

  /// Whether a new call can be made within the rate limit.
  bool get canMakeCall {
    _cleanup();
    return _callTimestamps.length < maxCalls;
  }

  /// Number of calls remaining in the current window.
  int get remainingCalls {
    _cleanup();
    return maxCalls - _callTimestamps.length;
  }

  /// Record that a call was made.
  void recordCall() {
    _callTimestamps.add(DateTime.now());
  }

  /// Wait until a call can be made, then run [fn].
  Future<T> waitAndRun<T>(Future<T> Function() fn) async {
    while (!canMakeCall) {
      final oldest = _callTimestamps.first;
      final waitUntil = oldest.add(window);
      final waitDuration = waitUntil.difference(DateTime.now());
      if (waitDuration.isNegative) {
        _cleanup();
        continue;
      }
      await Future.delayed(waitDuration);
    }
    recordCall();
    return fn();
  }

  /// Run [fn] immediately if within rate limit, otherwise throw.
  T runOrThrow<T>(T Function() fn) {
    if (!canMakeCall) {
      throw RateLimitExceededException(
        'Rate limit exceeded: $maxCalls calls per ${window.inSeconds}s',
      );
    }
    recordCall();
    return fn();
  }

  /// Remove timestamps outside the current window.
  void _cleanup() {
    final cutoff = DateTime.now().subtract(window);
    _callTimestamps.removeWhere((ts) => ts.isBefore(cutoff));
  }

  void reset() {
    _callTimestamps.clear();
  }
}

/// Exception thrown when a rate limit is exceeded.
class RateLimitExceededException implements Exception {
  final String message;
  final Duration? retryAfter;

  RateLimitExceededException(this.message, {this.retryAfter});

  @override
  String toString() => 'RateLimitExceededException: $message';
}
