import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralized Supabase Realtime subscription manager.
///
/// Subscribes to Postgres changes for all core tables within a household
/// and exposes ValueNotifiers that screens can listen to for reactive rebuilds.
class RealtimeService {
  RealtimeService._();
  static final RealtimeService instance = RealtimeService._();

  final SupabaseClient _client = Supabase.instance.client;
  RealtimeChannel? _channel;
  String? _householdId;

  /// Bump these versions from any listener; screens watch them to reload.
  final ValueNotifier<int> choresVersion = ValueNotifier(0);
  final ValueNotifier<int> shoppingVersion = ValueNotifier(0);
  final ValueNotifier<int> mealPlansVersion = ValueNotifier(0);
  final ValueNotifier<int> recipesVersion = ValueNotifier(0);
  final ValueNotifier<int> membersVersion = ValueNotifier(0);
  final ValueNotifier<int> pointsVersion = ValueNotifier(0);
  final ValueNotifier<int> rewardsVersion = ValueNotifier(0);
  final ValueNotifier<int> announcementsVersion = ValueNotifier(0);
  final ValueNotifier<int> mealRequestsVersion = ValueNotifier(0);

  /// Subscribe to all realtime channels for the given household.
  void subscribe(String householdId) {
    if (_householdId == householdId && _channel != null) return; // already subscribed
    unsubscribe(); // clean up any previous subscription
    _householdId = householdId;

    _channel = _client.channel('household:$householdId');

    // Chores
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => choresVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'chores',
    );

    // Shopping items
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => shoppingVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'shopping_items',
    );

    // Meal plans
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => mealPlansVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'meal_plans',
    );

    // Recipes
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => recipesVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'recipes',
    );

    // Household members
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => membersVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'household_members',
    );

    // Point transactions
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => pointsVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'point_transactions',
    );

    // Rewards
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => rewardsVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'rewards',
    );

    // Announcements
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => announcementsVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'announcements',
    );

    // Meal requests
    _channel!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      callback: (_) => mealRequestsVersion.value++,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'household_id',
        value: householdId,
      ),
      schema: 'public',
      table: 'meal_requests',
    );

    _channel!.subscribe();
  }

  /// Unsubscribe from all realtime channels.
  void unsubscribe() {
    if (_channel != null) {
      _client.removeChannel(_channel!);
      _channel = null;
    }
    _householdId = null;
  }

  /// Reset all version notifiers (used on sign-out).
  void reset() {
    unsubscribe();
    choresVersion.value = 0;
    shoppingVersion.value = 0;
    mealPlansVersion.value = 0;
    recipesVersion.value = 0;
    membersVersion.value = 0;
    pointsVersion.value = 0;
    rewardsVersion.value = 0;
    announcementsVersion.value = 0;
    mealRequestsVersion.value = 0;
  }
}
