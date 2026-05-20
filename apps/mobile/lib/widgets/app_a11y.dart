import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Accessibility utilities for semantics, contrast, and touch targets.
class AppA11y {
  AppA11y._();

  /// Minimum touch target size per WCAG guidelines (44x44 logical pixels).
  static const double minTouchTarget = 44.0;

  /// Wrap a widget with a semantic label.
  static Widget labeled({
    required String label,
    required Widget child,
    String? hint,
    bool enabled = true,
  }) {
    return Semantics(
      label: label,
      hint: hint,
      enabled: enabled,
      child: child,
    );
  }

  /// Wrap a widget with a semantic action.
  static Widget semanticAction({
    required String label,
    required VoidCallback onTap,
    required Widget child,
    String? hint,
  }) {
    return Semantics(
      label: label,
      hint: hint ?? 'Double tap to activate',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: child,
      ),
    );
  }

  /// Ensure a widget meets the minimum touch target size.
  static Widget touchTarget({
    required Widget child,
    double minSize = minTouchTarget,
    Alignment alignment = Alignment.center,
  }) {
    return SizedBox(
      width: minSize,
      height: minSize,
      child: Align(alignment: alignment, child: child),
    );
  }

  /// Create an accessible icon button with proper semantics.
  static Widget iconButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
    double size = 24.0,
  }) {
    return Semantics(
      label: label,
      button: true,
      child: IconButton(
        icon: Icon(icon, size: size, color: color),
        onPressed: onPressed,
        tooltip: label,
        constraints: const BoxConstraints(
          minWidth: minTouchTarget,
          minHeight: minTouchTarget,
        ),
      ),
    );
  }

  /// Check if a color provides sufficient contrast against a background.
  /// Uses a simplified luminance ratio check.
  static bool meetsContrastRatio(Color foreground, Color background, {double minRatio = 4.5}) {
    final fgLuminance = foreground.computeLuminance();
    final bgLuminance = background.computeLuminance();
    final lighter = fgLuminance > bgLuminance ? fgLuminance : bgLuminance;
    final darker = fgLuminance > bgLuminance ? bgLuminance : fgLuminance;
    final ratio = (lighter + 0.05) / (darker + 0.05);
    return ratio >= minRatio;
  }

  /// Get a color that ensures sufficient contrast against the given background.
  static Color ensureContrast(Color foreground, Color background, {double minRatio = 4.5}) {
    if (meetsContrastRatio(foreground, background, minRatio: minRatio)) {
      return foreground;
    }
    // Fall back to dark or light text based on background luminance
    return background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
  }
}

/// An accessible card widget with built-in semantics.
class AccessibleCard extends StatelessWidget {
  final Widget child;
  final String? label;
  final String? hint;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  const AccessibleCard({
    super.key,
    required this.child,
    this.label,
    this.hint,
    this.onTap,
    this.padding,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final card = Card(
      color: color,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );

    if (onTap == null && label == null) return card;

    return Semantics(
      label: label,
      hint: hint,
      button: onTap != null,
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: card,
            )
          : card,
    );
  }
}

/// An accessible status chip with semantic information.
class AccessibleStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const AccessibleStatusChip({
    super.key,
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Status: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
