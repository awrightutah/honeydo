import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

/// Subscription and payment screen for managing household premium tier.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  Map<String, dynamic>? _subscription;
  Map<String, dynamic>? _household;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      // Batch 7a-iii — Pattern A (LOW-risk): household-scoped screen, no
      // permission gating on _myMembership downstream. No listener needed.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership != null) {
        _household = membership['households'];
        final householdId = _household!['id'];

        // Load subscription
        final subs = await Supabase.instance.client
            .from('subscriptions')
            .select()
            .eq('household_id', householdId)
            .maybeSingle();

        if (subs != null) {
          _subscription = subs;
        } else {
          // Use household tier as fallback
          _subscription = {
            'tier': _household!['tier'] ?? 'free',
            'status': _household!['subscription_status'] ?? 'active',
          };
        }
      }
    } catch (e) {
      debugPrint('subscription_screen load failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading subscription: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Subscription', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Current plan card
                  _buildCurrentPlanCard(),
                  const SizedBox(height: 24),

                  // Features comparison
                  Text('FEATURES', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  )),
                  const SizedBox(height: 12),
                  _buildFeaturesComparison(),
                  const SizedBox(height: 24),

                  // Upgrade options
                  if (_subscription?['tier'] == 'free') ...[
                    Text('UPGRADE TO PREMIUM', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    )),
                    const SizedBox(height: 12),
                    _buildPremiumCard(),
                    const SizedBox(height: 24),
                  ],

                  // Payment info
                  Text('PAYMENT', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  )),
                  const SizedBox(height: 12),
                  _buildPaymentInfo(),
                  const SizedBox(height: 24),

                  // Cancel subscription
                  if (_subscription?['tier'] == 'premium' && _subscription?['status'] == 'active')
                    _buildCancelSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildCurrentPlanCard() {
    final tier = _subscription?['tier'] ?? 'free';
    final status = _subscription?['status'] ?? 'active';
    final isPremium = tier == 'premium';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isPremium
              ? [AppColors.honeyGold, AppColors.honeyGold.withValues(alpha:.7)]
              : [Colors.grey.shade700, Colors.grey.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPremium ? Icons.workspace_premium_rounded : Icons.card_membership_rounded,
                color: Colors.white,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPremium ? 'Premium Plan' : 'Free Plan',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _formatStatus(status),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha:.8),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isPremium && _subscription?['current_period_ends_at'] != null)
            Text(
              'Renews on ${_formatDate(_subscription!['current_period_ends_at'])}',
              style: TextStyle(
                color: Colors.white.withValues(alpha:.7),
                fontSize: 13,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeaturesComparison() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _featureRow('Unlimited household members', true, true),
            _featureRow('Chore assignment & tracking', true, true),
            _featureRow('Meal planning', true, true),
            _featureRow('Shopping lists', true, true),
            _featureRow('Recipe library', true, true),
            _featureRow('Calendar events', true, true),
            _featureRow('Gamification (points, badges)', true, true),
            _featureRow('Push notifications', true, true),
            _featureRow('Recipe URL import', false, true),
            _featureRow('Custom rewards', false, true),
            _featureRow('Advanced analytics', false, true),
            _featureRow('Priority support', false, true),
          ],
        ),
      ),
    );
  }

  Widget _featureRow(String feature, bool free, bool premium) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Center(
              child: Icon(
                free ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 20,
                color: free ? AppColors.grassGreen : Colors.grey.shade400,
              ),
            ),
          ),
          Expanded(
            child: Text(
              feature,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: 80,
            child: Center(
              child: Icon(
                premium ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 20,
                color: premium ? AppColors.grassGreen : Colors.grey.shade400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.honeyGold, Color(0xFFE8941C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Honeydo Premium',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '\$9.99/month',
            style: TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Unlock all features including recipe imports, custom rewards, and advanced analytics.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _showPaymentDialog,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.honeyGold,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Upgrade Now', style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.credit_card_rounded, color: AppColors.skyBlue),
                const SizedBox(width: 12),
                Text(
                  'Payment Method',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_subscription?['tier'] == 'premium')
              Text(
                'Managed securely via Authorize.net',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              Text(
                'No payment method on file',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _showPaymentDialog,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Payment Method'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCancelSection() {
    return Card(
      color: AppColors.coral.withValues(alpha:.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_rounded, color: AppColors.coral),
                const SizedBox(width: 12),
                Text(
                  'Cancel Subscription',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.coral,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'If you cancel, you\'ll retain premium features until the end of your billing period.',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _showCancelDialog,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.coral,
                side: BorderSide(color: AppColors.coral),
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('Cancel Subscription'),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaymentDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Payment Setup'),
        content: const Text(
          'In a production environment, this would integrate with Authorize.net '
          'to securely collect payment information. For this demo, payment processing '
          'is simulated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Payment setup simulated!')),
              );
            },
            child: const Text('Simulate Payment'),
          ),
        ],
      ),
    );
  }

  void _showCancelDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Subscription?'),
        content: const Text(
          'Are you sure you want to cancel your premium subscription? '
          'You\'ll lose access to premium features at the end of your billing period.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep Subscription'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cancellation simulated!')),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Cancel Subscription'),
          ),
        ],
      ),
    );
  }

  String _formatStatus(String status) {
    switch (status) {
      case 'active':
        return 'Active';
      case 'trialing':
        return 'Trial';
      case 'past_due':
        return 'Past Due';
      case 'cancelled':
        return 'Cancelled';
      case 'expired':
        return 'Expired';
      default:
        return status;
    }
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return 'Unknown';
    }
  }
}