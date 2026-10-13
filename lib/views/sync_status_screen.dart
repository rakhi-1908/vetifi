import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/sync_service.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({
    super.key,
    required this.databaseService,
    required this.pendingLogCount,
    required this.isSyncing,
    required this.lastSyncResult,
    required this.onSyncNow,
  });

  final DatabaseService databaseService;
  final int pendingLogCount;
  final bool isSyncing;
  final SyncResult? lastSyncResult;
  final Future<void> Function() onSyncNow;

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  late Future<List<Map<String, dynamic>>> _pendingLogs;
  bool _isManualSyncing = false;

  @override
  void initState() {
    super.initState();
    _pendingLogs = widget.databaseService.getPendingCalculationLogs();
  }

  @override
  void didUpdateWidget(covariant SyncStatusScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastSyncResult != widget.lastSyncResult ||
        oldWidget.pendingLogCount != widget.pendingLogCount) {
      _pendingLogs = widget.databaseService.getPendingCalculationLogs();
    }
  }

  Future<void> _reload() async {
    final logs = widget.databaseService.getPendingCalculationLogs();
    if (!mounted) return;
    setState(() {
      _pendingLogs = logs;
    });
  }

  Future<void> _syncNow() async {
    if (_isManualSyncing) return;
    setState(() {
      _isManualSyncing = true;
    });
    try {
      await widget.onSyncNow();
      await _reload();
    } finally {
      if (mounted) {
        setState(() {
          _isManualSyncing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.lastSyncResult;
    final isSyncing = widget.isSyncing || _isManualSyncing;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync and calculation outbox')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _pendingLogs,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to read the local calculation outbox: '
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final logs = snapshot.data;
          if (logs == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isSyncing
                                  ? Icons.sync
                                  : logs.isEmpty
                                  ? Icons.cloud_done_outlined
                                  : Icons.cloud_upload_outlined,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.isSyncing
                                    ? 'Sync in progress'
                                    : '${logs.length} calculation'
                                          '${logs.length == 1 ? '' : 's'} pending',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Calculations are saved on this device first. '
                          'Pending entries upload when connectivity is available.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (result != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _statusLabel(result),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color:
                                  result.status == SyncStatus.failed ||
                                      result.status == SyncStatus.rejected
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                          if (result.message != null) ...[
                            const SizedBox(height: 4),
                            Text(result.message!),
                          ],
                          if (result.version != null) ...[
                            const SizedBox(height: 4),
                            Text('Dataset: ${result.version}'),
                          ],
                          if (result.uploadedCalculationLogs > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Uploaded ${result.uploadedCalculationLogs} '
                              'calculation log'
                              '${result.uploadedCalculationLogs == 1 ? '' : 's'}.',
                            ),
                          ],
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const ValueKey('sync-now'),
                            onPressed: isSyncing ? null : _syncNow,
                            icon: isSyncing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.sync),
                            label: Text(isSyncing ? 'Syncing…' : 'Sync now'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Pending calculation logs',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (logs.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.check_circle_outline),
                      title: Text('Outbox is empty'),
                    ),
                  )
                else
                  ...logs.map((log) => _CalculationLogCard(log: log)),
              ],
            ),
          );
        },
      ),
    );
  }

  String _statusLabel(SyncResult result) {
    return switch (result.status) {
      SyncStatus.offline => 'Offline',
      SyncStatus.current => 'Dataset is up to date',
      SyncStatus.updated => 'Dataset updated',
      SyncStatus.rejected => 'Update rejected',
      SyncStatus.failed => 'Sync failed',
    };
  }
}

class _CalculationLogCard extends StatelessWidget {
  const _CalculationLogCard({required this.log});

  final Map<String, dynamic> log;

  @override
  Widget build(BuildContext context) {
    final inputs = _asMap(log['inputs']);
    final result = _asMap(log['result']);
    final drugName = inputs['drug_name']?.toString() ?? 'Calculation';
    final weight = inputs['weight']?.toString() ?? '—';
    final weightUnit = inputs['weight_unit']?.toString() ?? 'kg';
    final species = inputs['species']?.toString() ?? '—';
    final datasetVersion = log['dataset_version']?.toString() ?? 'unknown';

    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.receipt_long_outlined),
        title: Text(drugName),
        subtitle: Text(
          '$weight $weightUnit · $species · dataset $datasetVersion',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _LogDetail(
            label: 'Dose',
            value: _formatEntry(inputs, 'dose', 'dose_unit'),
          ),
          _LogDetail(
            label: 'Total dose',
            value: '${result['total_dose_mg'] ?? '—'} mg',
          ),
          _LogDetail(
            label: 'Volume',
            value: '${result['volume_ml'] ?? '—'} mL',
          ),
          _LogDetail(
            label: 'Idempotency key',
            value: log['idempotency_key']?.toString() ?? '—',
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  String _formatEntry(
    Map<String, dynamic> map,
    String valueKey,
    String unitKey,
  ) {
    final value = map[valueKey];
    final unit = map[unitKey];
    return value == null ? '—' : '$value ${unit ?? ''}'.trim();
  }
}

class _LogDetail extends StatelessWidget {
  const _LogDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
