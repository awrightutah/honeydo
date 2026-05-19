import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Service that listens to Supabase Realtime changes for the current household
/// and provides ValueNotifiers that screens can react to.
class RealtimeService {
  RealtimeService._();
  static final RealtimeService instance = RealtimeService._();

  String? _householdId;
  RealtimeChannel? _channel;

  /// Notifiers that screens can listen to for real-time updates
  final ValueNotifier<int> choresVersion = ValueNotifier(0);
  final ValueNotifier<int> shoppingVersion = ValueNotifier(0);
  final ValueNotifier<int> mealPlansVersion = ValueNotifier(0);
  final ValueNotifier<int> recipesVersion = ValueNotifier(0);
  final ValueNotifier<int> membersVersion = ValueNotifier(0);
  final ValueNotifier<int> pointsVersion = ValueNotifier(0);
  final ValueNotifier<int> rewardsVersion = ValueNotifier(0);

  /// Start listening to realtime events for a household
  void subscribe(String householdId) {
    if (_householdId == householdId && _channel != null) return;

    // Unsubscribe from previous household if any
    unsubscribe();

    _householdId = householdId;

    _channel = Supabase.instance.client.channel('household:$householdId');

    // Listen to chores changes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chores',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) {
        choresVersion.value++;
        // Points may change when chores are verified
        if (payload.eventType == PostgresChangeEvent.update) {
          pointsVersion.value++;
        }
      },
    );

    // Listen to shopping items changes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'shopping_items',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) => shoppingVersion.value++,
    );

    // Listen to meal plans changes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'meal_plans',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) => mealPlansVersion.value++,
    );

    // Listen to household recipes changes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'household_recipes',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) => recipesVersion.value++,
    );

    // Listen to member changes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'household_members',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) {
        membersVersion.value++;
        pointsVersion.value++;
      },
    );

    // Listen to point transactions
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'point_transactions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) => pointsVersion.value++,
    );

    // Listen to reward redemptions
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'reward_redemptions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      callback: (payload) => rewardsVersion.value++,
    );

    _channel!.subscribe();
  }

  /// Stop listening to realtime events
  void unsubscribe() {
    if (_channel != null) {
      Supabase.instance.client.removeChannel(_channel!);
      _channel = null;
    }
    _householdId = null;
  }

  /// Reset all version notifiers (e.g., on sign out)
  void reset() {
    unsubscribe();
    choresVersion.value = 0;
    shoppingVersion.value = 0;
    mealPlansVersion.value = 0;
    recipesVersion.value = 0;
    membersVersion.value = 0;
    pointsVersion.value = 0;
    rewardsVersion.value = 0;
  }
}
