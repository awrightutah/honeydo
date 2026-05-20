import 'package:flutter/material.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';

/// A banner widget that shows at the top of the screen when the device is offline.
/// Place this at the top of your Scaffold body.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: OfflineService.instance.isOnline,
      builder: (context, isOnline, _) {
        if (isOnline) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF7043), Color(0xFFFF5722)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withOpacity(.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'You\'re offline. Changes will sync when you reconnect.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: OfflineService.instance.pendingOperationsCount,
                builder: (context, count, _) {
                  if (count == 0) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.25),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      '$count pending',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
