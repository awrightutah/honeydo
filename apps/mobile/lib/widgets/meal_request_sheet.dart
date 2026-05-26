import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';

/// Kid-only bottom sheet to request a household recipe as a meal.
///
/// Both date and meal-type are optional ("Any day" / "Any meal"). If the
/// kid leaves either unset, admin must supply it at approve-time — the
/// `decide_meal_request` RPC raises if final date/meal_type are still
/// null after the COALESCE with override params.
///
/// Calls `create_meal_request` RPC (migration 0017). Inserts a row with
/// status='pending'. Kid does not see their own pending request status
/// anywhere in 6a — that's the recent-requests view in 6b.
///
/// Use [MealRequestSheet.show] as the entry point.
class MealRequestSheet extends StatefulWidget {
  const MealRequestSheet({
    super.key,
    required this.recipeId,
    required this.recipeTitle,
  });

  final String recipeId;
  final String recipeTitle;

  /// Opens the sheet. Returns `true` if the kid submitted a request,
  /// `false` (or null) if they cancelled.
  static Future<bool?> show(
    BuildContext context, {
    required String recipeId,
    required String recipeTitle,
  }) =>
      showModalBottomSheet<bool?>(
        context: context,
        isScrollControlled: true,
        builder: (_) => MealRequestSheet(
          recipeId: recipeId,
          recipeTitle: recipeTitle,
        ),
      );

  @override
  State<MealRequestSheet> createState() => _MealRequestSheetState();
}

class _MealRequestSheetState extends State<MealRequestSheet> {
  DateTime? _selectedDate;
  String? _selectedMealType;
  bool _isSubmitting = false;

  // Mirrors the Postgres meal_type enum.
  static const _mealTypes = [
    'breakfast',
    'lunch',
    'dinner',
    'snack',
    'other',
  ];

  static const _mealTypeEmojis = {
    'breakfast': '🌅',
    'lunch': '☀️',
    'dinner': '🌙',
    'snack': '🍎',
    'other': '🍽️',
  };

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);
    try {
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership == null) {
        throw Exception('No household membership found');
      }
      if (!Permissions.isKid(membership)) {
        // Defensive: this sheet should only ever open for kids. If somehow
        // it does for an adult, bail with a clear message.
        throw Exception('Only kid profiles can request meals');
      }

      await Supabase.instance.client.rpc('create_meal_request', params: {
        'p_household_id': membership['household_id'],
        'p_member_id': membership['id'],
        'p_recipe_id': widget.recipeId,
        'p_requested_for_date':
            _selectedDate?.toIso8601String().split('T').first,
        'p_meal_type': _selectedMealType,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request sent — waiting for admin approval'),
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('create_meal_request failed: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't send request: $e")),
        );
      }
    }
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final monthStr = months[d.month - 1];
    final now = DateTime.now();
    if (d.year == now.year) return '$monthStr ${d.day}';
    return '$monthStr ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Request this meal',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                widget.recipeTitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),

              // --- When? ---
              const Text(
                'When?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                "Optional — admin can pick if you're flexible",
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: _isSubmitting ? null : _pickDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_rounded, size: 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _selectedDate == null
                              ? 'Any day'
                              : _formatDate(_selectedDate!),
                          style: TextStyle(
                            color: _selectedDate == null
                                ? Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant
                                : null,
                          ),
                        ),
                      ),
                      if (_selectedDate != null)
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          tooltip: 'Clear date',
                          onPressed: _isSubmitting
                              ? null
                              : () => setState(() => _selectedDate = null),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // --- What meal? ---
              const Text(
                'What meal?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                'Optional',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                value: _selectedMealType,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.restaurant_menu_rounded),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Any meal'),
                  ),
                  ..._mealTypes.map((m) => DropdownMenuItem<String?>(
                        value: m,
                        child: Text(
                          '${_mealTypeEmojis[m] ?? ''} '
                          '${m[0].toUpperCase()}${m.substring(1)}',
                        ),
                      )),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (v) => setState(() => _selectedMealType = v),
              ),
              const SizedBox(height: 28),

              // --- Submit ---
              FilledButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_isSubmitting ? 'Sending…' : 'Send request'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.honeyGold,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
