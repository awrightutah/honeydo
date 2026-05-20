import 'package:flutter/material.dart';
import 'app_error.dart';

/// Error boundary widget that catches errors in its child subtree.
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(BuildContext context, FlutterErrorDetails details)? errorBuilder;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  FlutterErrorDetails? _errorDetails;

  @override
  Widget build(BuildContext context) {
    if (_errorDetails != null) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, _errorDetails!);
      }
      return ErrorView(
        message: 'Something went wrong. Please try again.',
        onRetry: () {
          setState(() => _errorDetails = null);
        },
      );
    }
    return widget.child;
  }
}

/// Builder widget for async operations with loading, error, and empty states.
class AsyncScreenBuilder<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final String? loadingMessage;
  final String? emptyMessage;
  final IconData emptyIcon;
  final Widget? emptyAction;
  final VoidCallback? onRetry;

  const AsyncScreenBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.loadingMessage,
    this.emptyMessage = 'Nothing here yet',
    this.emptyIcon = Icons.inbox_rounded,
    this.emptyAction,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return LoadingView(message: loadingMessage);
        }

        if (snapshot.hasError) {
          return ErrorView(
            message: _friendlyError(snapshot.error.toString()),
            onRetry: onRetry,
          );
        }

        final data = snapshot.data;
        if (data == null) {
          return EmptyView(
            message: emptyMessage!,
            icon: emptyIcon,
            action: emptyAction,
          );
        }

        // Handle empty lists
        if (data is List && data.isEmpty) {
          return EmptyView(
            message: emptyMessage!,
            icon: emptyIcon,
            action: emptyAction,
          );
        }

        return builder(context, data);
      },
    );
  }

  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('network') || lower.contains('socket') || lower.contains('connection')) {
      return 'No internet connection. Please check your network and try again.';
    }
    if (lower.contains('unauthorized') || lower.contains('401')) {
      return 'Your session has expired. Please sign in again.';
    }
    if (lower.contains('timeout')) {
      return 'The request timed out. Please try again.';
    }
    return 'Something went wrong. Please try again.';
  }
}

/// Builder widget for async operations that uses snapshots (e.g., StreamBuilder).
class AsyncListBuilder<T> extends StatelessWidget {
  final AsyncSnapshot<T> snapshot;
  final Widget Function(BuildContext context, T data) builder;
  final String? loadingMessage;
  final String? emptyMessage;
  final IconData emptyIcon;
  final Widget? emptyAction;
  final VoidCallback? onRetry;

  const AsyncListBuilder({
    super.key,
    required this.snapshot,
    required this.builder,
    this.loadingMessage,
    this.emptyMessage = 'Nothing here yet',
    this.emptyIcon = Icons.inbox_rounded,
    this.emptyAction,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return LoadingView(message: loadingMessage);
    }

    if (snapshot.hasError) {
      return ErrorView(
        message: _friendlyError(snapshot.error.toString()),
        onRetry: onRetry,
      );
    }

    final data = snapshot.data;
    if (data == null || (data is List && data.isEmpty)) {
      return EmptyView(
        message: emptyMessage!,
        icon: emptyIcon,
        action: emptyAction,
      );
    }

    return builder(context, data);
  }

  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('network') || lower.contains('socket') || lower.contains('connection')) {
      return 'No internet connection. Please check your network and try again.';
    }
    if (lower.contains('unauthorized') || lower.contains('401')) {
      return 'Your session has expired. Please sign in again.';
    }
    if (lower.contains('timeout')) {
      return 'The request timed out. Please try again.';
    }
    return 'Something went wrong. Please try again.';
  }
}
