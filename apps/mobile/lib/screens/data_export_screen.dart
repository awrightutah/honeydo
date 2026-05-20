import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Screen for exporting household data as JSON or CSV.
class DataExportScreen extends StatefulWidget {
  const DataExportScreen({super.key});

  @override
  State<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends State<DataExportScreen> {
  final _supabase = Supabase.instance.client;
  bool _isExporting = false;
  ExportFormat _format = ExportFormat.json;

  final Map<String, bool> _sections = {
    'Chores': true,
    'Shopping List': true,
    'Meal Plans': true,
    'Recipes': true,
    'Household Members': true,
    'Rewards & Points': true,
    'Announcements': true,
    'Calendar Events': true,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Data'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Format selector
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Export Format', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SegmentedButton<ExportFormat>(
                    segments: const [
                      ButtonSegment(value: ExportFormat.json, label: Text('JSON'), icon: Icon(Icons.data_object)),
                      ButtonSegment(value: ExportFormat.csv, label: Text('CSV'), icon: Icon(Icons.table_chart)),
                    ],
                    selected: {_format},
                    onSelectionChanged: (s) => setState(() => _format = s.first),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Section selector
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Sections', style: Theme.of(context).textTheme.titleMedium),
                      TextButton(
                        onPressed: _toggleAll,
                        child: Text(_sections.values.every((v) => v) ? 'Deselect All' : 'Select All'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._sections.keys.map((key) => CheckboxListTile(
                    title: Text(key),
                    value: _sections[key],
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => _sections[key] = v ?? false),
                  )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Export button
          FilledButton.icon(
            onPressed: _isExporting ? null : _export,
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(_isExporting ? 'Exporting…' : 'Export & Share'),
          ),
          const SizedBox(height: 8),
          Text(
            'Your data will be processed locally and shared via your preferred app.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _toggleAll() {
    final allSelected = _sections.values.every((v) => v);
    setState(() {
      for (final key in _sections.keys) {
        _sections[key] = !allSelected;
      }
    });
  }

  Future<void> _export() async {
    setState(() => _isExporting = true);
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not authenticated');

      // Get user's household
      final memberRes = await _supabase
          .from('household_members')
          .select('household_id')
          .eq('auth_user_id', user.id)
          .maybeSingle();

      if (memberRes == null) throw Exception('No household found');

      final householdId = memberRes['household_id'] as String;
      final data = <String, dynamic>{};

      if (_sections['Chores']!) {
        data['chores'] = await _supabase
            .from('chores')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Shopping List']!) {
        data['shopping_items'] = await _supabase
            .from('shopping_items')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Meal Plans']!) {
        data['meal_plans'] = await _supabase
            .from('meal_plans')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Recipes']!) {
        data['recipes'] = await _supabase
            .from('recipes')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Household Members']!) {
        data['members'] = await _supabase
            .from('household_members')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Rewards & Points']!) {
        data['point_transactions'] = await _supabase
            .from('point_transactions')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Announcements']!) {
        data['announcements'] = await _supabase
            .from('announcements')
            .select('*')
            .eq('household_id', householdId);
      }
      if (_sections['Calendar Events']!) {
        data['calendar_events'] = await _supabase
            .from('calendar_events')
            .select('*')
            .eq('household_id', householdId);
      }

      data['exported_at'] = DateTime.now().toIso8601String();
      data['household_id'] = householdId;

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

      if (_format == ExportFormat.json) {
        await _exportAsJson(data, timestamp);
      } else {
        await _exportAsCsv(data, timestamp);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: AppColors.coral),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportAsJson(Map<String, dynamic> data, String timestamp) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/honeydo_export_$timestamp.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Honeydo Household Data Export',
    );
  }

  Future<void> _exportAsCsv(Map<String, dynamic> data, String timestamp) async {
    final dir = await getTemporaryDirectory();
    final buffer = StringBuffer();

    for (final entry in data.entries) {
      if (entry.value is! List) continue;
      final rows = entry.value as List;
      if (rows.isEmpty) continue;

      buffer.writeln('# ${entry.key}');
      final firstRow = rows.first as Map<String, dynamic>;
      buffer.writeln(firstRow.keys.join(','));
      for (final row in rows) {
        final m = row as Map<String, dynamic>;
        buffer.writeln(m.values.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(','));
      }
      buffer.writeln();
    }

    final file = File('${dir.path}/honeydo_export_$timestamp.csv');
    await file.writeAsString(buffer.toString());
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Honeydo Household Data Export (CSV)',
    );
  }
}

enum ExportFormat { json, csv }
