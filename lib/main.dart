import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'models/drug_model.dart';
import 'services/database_service.dart';
import 'services/dose_calculator.dart';
import 'services/search_service.dart';
import 'services/sync_service.dart';
import 'views/dose_calculator_screen.dart';
import 'views/sync_status_screen.dart';

const _configuredApiBaseUrl = String.fromEnvironment(
  'VETIFI_API_BASE_URL',
  defaultValue: '',
);

Uri get _defaultApiBaseUri {
  if (_configuredApiBaseUrl.isNotEmpty) {
    return Uri.parse(_configuredApiBaseUrl);
  }
  return Uri.parse(
    Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://localhost:8000',
  );
}

void main() {
  runApp(const VetifiApp());
}

class VetifiApp extends StatefulWidget {
  const VetifiApp({
    super.key,
    this.databaseService,
    this.searchService,
    this.apiBaseUri,
    this.enableBackgroundSync = true,
  });

  final DatabaseService? databaseService;
  final SearchService? searchService;
  final Uri? apiBaseUri;
  final bool enableBackgroundSync;

  @override
  State<VetifiApp> createState() => _VetifiAppState();
}

class _VetifiAppState extends State<VetifiApp> {
  late final DatabaseService _databaseService;
  late final SearchService _searchService;
  late final SyncService _syncService;
  late final DoseCalculatorService _doseCalculator;

  int _pendingLogCount = 0;
  bool _isSyncing = false;
  SyncResult? _lastSyncResult;

  @override
  void initState() {
    super.initState();
    _databaseService = widget.databaseService ?? DatabaseService();
    _searchService =
        widget.searchService ??
        SearchService(databaseService: _databaseService);
    _syncService = SyncService(
      databaseService: _databaseService,
      apiBaseUri: widget.apiBaseUri ?? _defaultApiBaseUri,
    );
    _doseCalculator = const DoseCalculatorService();
    unawaited(_initializeSync());
  }

  Future<void> _initializeSync() async {
    try {
      await _databaseService.database;
      await _refreshPendingCount();
      if (!widget.enableBackgroundSync || !mounted) return;
      _syncService.startBackgroundSync(
        onResult: (result) => unawaited(_handleBackgroundResult(result)),
        onError: (error, _) {
          if (!mounted) return;
          setState(() {
            _lastSyncResult = SyncResult(
              status: SyncStatus.failed,
              message: error.toString(),
            );
          });
          unawaited(_refreshPendingCount());
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastSyncResult = SyncResult(
          status: SyncStatus.failed,
          message: 'Unable to initialize local sync: $error',
        );
      });
    }
  }

  Future<void> _handleBackgroundResult(SyncResult result) async {
    try {
      if (result.status == SyncStatus.updated) {
        await _searchService.refreshClinicalIndex();
      }
      if (!mounted) return;
      setState(() {
        _lastSyncResult = result;
      });
      await _refreshPendingCount();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastSyncResult = SyncResult(
          status: SyncStatus.failed,
          message: 'Could not refresh local data after sync: $error',
        );
      });
    }
  }

  Future<void> _refreshPendingCount() async {
    try {
      final pending = await _databaseService.getPendingCalculationLogs();
      if (!mounted) return;
      setState(() {
        _pendingLogCount = pending.length;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastSyncResult = SyncResult(
          status: SyncStatus.failed,
          message: 'Unable to read the local calculation outbox: $error',
        );
      });
    }
  }

  Future<void> _syncNow() async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
    });
    try {
      final result = await _syncService.synchronize();
      if (result.status == SyncStatus.updated) {
        await _searchService.refreshClinicalIndex();
      }
      final uploadedCount = await _syncService.syncPendingCalculationLogs();
      if (!mounted) return;
      setState(() {
        _lastSyncResult = SyncResult(
          status: result.status,
          version: result.version,
          message: result.message,
          uploadedCalculationLogs: uploadedCount,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastSyncResult = SyncResult(
          status: SyncStatus.failed,
          message: error.toString(),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
        await _refreshPendingCount();
      }
    }
  }

  Future<void> _calculationLogged() async {
    await _refreshPendingCount();
    try {
      final uploadedCount = await _syncService.syncPendingCalculationLogs();
      if (uploadedCount > 0 && mounted) {
        setState(() {
          _lastSyncResult = SyncResult(
            status: SyncStatus.current,
            uploadedCalculationLogs: uploadedCount,
          );
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _lastSyncResult = SyncResult(
            status: SyncStatus.failed,
            message: 'Calculation log sync failed: $error',
          );
        });
      }
    } finally {
      await _refreshPendingCount();
    }
  }

  @override
  void dispose() {
    unawaited(_syncService.stopBackgroundSync());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vetifi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF087E8B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F8F8),
      ),
      home: DrugSearchScreen(
        databaseService: _databaseService,
        searchService: _searchService,
        doseCalculator: _doseCalculator,
        pendingLogCount: _pendingLogCount,
        isSyncing: _isSyncing,
        lastSyncResult: _lastSyncResult,
        onSyncNow: _syncNow,
        onCalculationLogged: _calculationLogged,
      ),
    );
  }
}

class DrugSearchScreen extends StatefulWidget {
  const DrugSearchScreen({
    super.key,
    required this.databaseService,
    required this.searchService,
    required this.doseCalculator,
    required this.pendingLogCount,
    required this.isSyncing,
    required this.lastSyncResult,
    required this.onSyncNow,
    required this.onCalculationLogged,
  });

  final DatabaseService databaseService;
  final SearchService searchService;
  final DoseCalculatorService doseCalculator;
  final int pendingLogCount;
  final bool isSyncing;
  final SyncResult? lastSyncResult;
  final Future<void> Function() onSyncNow;
  final Future<void> Function() onCalculationLogged;

  @override
  State<DrugSearchScreen> createState() => _DrugSearchScreenState();
}

class _DrugSearchScreenState extends State<DrugSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<DrugSearchResult> _results = const [];
  bool _isLoading = true;
  String? _errorMessage;
  int _queryGeneration = 0;
  String? _datasetVersion;

  @override
  void didUpdateWidget(covariant DrugSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastSyncResult != widget.lastSyncResult &&
        widget.lastSyncResult?.status == SyncStatus.updated) {
      _refreshDatasetVersion();
    }
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await widget.searchService.initialize();
      final version = await widget.databaseService.getDatasetVersion();
      if (!mounted) return;
      setState(() {
        _datasetVersion = version;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to load the local drug database: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshDatasetVersion() async {
    try {
      final version = await widget.databaseService.getDatasetVersion();
      if (!mounted) return;
      setState(() {
        _datasetVersion = version;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to refresh the local dataset version: $error';
      });
    }
  }

  Future<void> _search(String query) async {
    final generation = ++_queryGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _results = const [];
        _errorMessage = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final results = await widget.searchService.search(query);
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _results = results;
        _isLoading = false;
      });
    } on SearchCancelledException {
      // A newer query owns the visible result state.
    } catch (error) {
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _errorMessage = 'Search failed: $error';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Vetifi',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_datasetVersion != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Semantics(
                  label: 'Offline dataset version $_datasetVersion',
                  child: Chip(
                    avatar: const Icon(Icons.offline_pin, size: 18),
                    label: Text(_datasetVersion!),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: '${widget.pendingLogCount} pending calculation logs',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SyncStatusScreen(
                    databaseService: widget.databaseService,
                    pendingLogCount: widget.pendingLogCount,
                    isSyncing: widget.isSyncing,
                    lastSyncResult: widget.lastSyncResult,
                    onSyncNow: widget.onSyncNow,
                  ),
                ),
              );
            },
            icon: _SyncStatusIcon(
              pendingCount: widget.pendingLogCount,
              isSyncing: widget.isSyncing,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Clinical drug search',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Search the locally available veterinary drug database.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _searchController,
                    onChanged: _search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search drugs by name',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                _search('');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResults(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading drug data'),
      );
    }
    final errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            errorMessage,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (_searchController.text.trim().isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Enter a drug name to search.'),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching drugs found.'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) => DrugResultCard(
        result: _results[index],
        onTap: () {
          final drug = _results[index].drug;
          if (drug == null) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => DrugDetailsScreen(
                drug: drug,
                databaseService: widget.databaseService,
                doseCalculator: widget.doseCalculator,
                onCalculationLogged: widget.onCalculationLogged,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SyncStatusIcon extends StatelessWidget {
  const _SyncStatusIcon({required this.pendingCount, required this.isSyncing});

  final int pendingCount;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: isSyncing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined),
        ),
        if (pendingCount > 0)
          Positioned(
            right: 0,
            top: -4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  pendingCount > 99 ? '99+' : '$pendingCount',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onError,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class DrugDetailsScreen extends StatelessWidget {
  const DrugDetailsScreen({
    super.key,
    required this.drug,
    this.databaseService,
    this.doseCalculator,
    this.onCalculationLogged,
  });

  final Drug drug;
  final DatabaseService? databaseService;
  final DoseCalculatorService? doseCalculator;
  final Future<void> Function()? onCalculationLogged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(drug.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drug.name,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  _DrugDetailRow(
                    label: 'Concentration',
                    value: drug.concentration,
                  ),
                  _DrugDetailRow(label: 'Route', value: drug.route),
                  if (drug.maxTotalMg != null)
                    _DrugDetailRow(
                      label: 'Maximum total dose',
                      value: '${_formatDose(drug.maxTotalMg!)} mg',
                    ),
                  if (drug.isWithdrawn)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'Withdrawn — do not use.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!drug.isWithdrawn &&
              drug.doses.isNotEmpty &&
              databaseService != null &&
              doseCalculator != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('open-dose-calculator'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DoseCalculatorScreen(
                      drug: drug,
                      databaseService: databaseService!,
                      doseCalculator: doseCalculator!,
                      onCalculationLogged: onCalculationLogged,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.calculate_outlined),
              label: const Text('Calculate dose'),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Dose ranges',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (drug.doses.isEmpty)
            const Card(
              child: ListTile(title: Text('No dose information available')),
            )
          else
            ...drug.doses.entries.map(
              (entry) => Card(
                child: ListTile(
                  leading: const Icon(Icons.pets_outlined),
                  title: Text(_capitalize(entry.key)),
                  subtitle: Text(
                    '${_formatDose(entry.value.min)}–'
                    '${_formatDose(entry.value.max)} ${entry.value.unit}',
                  ),
                ),
              ),
            ),
          if (drug.criRanges.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'CRI ranges',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...drug.criRanges.map(
              (range) => Card(
                child: ListTile(
                  leading: const Icon(Icons.water_drop_outlined),
                  title: Text(
                    range.species == null
                        ? 'All species'
                        : _capitalize(range.species!),
                  ),
                  subtitle: Text(
                    '${_formatDose(range.min)}–${_formatDose(range.max)} '
                    '${range.unit}',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

  static String _formatDose(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
}

class _DrugDetailRow extends StatelessWidget {
  const _DrugDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class DrugResultCard extends StatelessWidget {
  const DrugResultCard({super.key, required this.result, required this.onTap});

  final DrugSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final drug = result.drug;
    if (drug == null) return const SizedBox.shrink();
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: onTap,
        title: Text(
          drug.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('${drug.concentration}  ·  ${drug.route}'),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
