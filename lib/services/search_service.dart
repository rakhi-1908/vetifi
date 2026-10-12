import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:collection';

import 'package:sqflite/sqflite.dart';

import '../models/drug_model.dart';
import 'database_service.dart';

class SearchCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

class SearchCancelledException implements Exception {
  const SearchCancelledException();

  @override
  String toString() => 'Search request was cancelled or superseded.';
}

enum SearchMatchType { exact, prefix, approximate }

class DrugSearchResult {
  const DrugSearchResult({
    required this.id,
    required this.name,
    required this.isBenchmark,
    required this.matchType,
    required this.data,
  });

  final String id;
  final String name;
  final bool isBenchmark;
  final SearchMatchType matchType;
  final Map<String, dynamic> data;

  Drug? get drug => isBenchmark ? null : Drug.fromJson(data);
}

class SearchPerformanceReport {
  const SearchPerformanceReport({
    required this.sampleCount,
    required this.typicalLatency,
    required this.worstCaseLatency,
  });

  final int sampleCount;
  final Duration typicalLatency;
  final Duration worstCaseLatency;
}

class SearchService {
  SearchService({required DatabaseService databaseService})
    : _databaseService = databaseService;

  static const int defaultBenchmarkEntryCount = 50000;
  static const int _seedBatchSize = 500;
  static const int _maxFuzzyCandidates = 400;
  static const int _maxLatencySamples = 200;

  final DatabaseService _databaseService;
  final Queue<Duration> _latencies = Queue<Duration>();
  Future<void>? _initializing;
  int _requestGeneration = 0;

  Future<void> initialize({bool seedBenchmarkData = false}) async {
    await (_initializing ??= _initialize());
    if (seedBenchmarkData &&
        await benchmarkEntryCount() != defaultBenchmarkEntryCount) {
      await seedBenchmarkEntries();
    }
  }

  Future<void> _initialize() async {
    final db = await _databaseService.database;
    await _createSearchSchema(db);
    await refreshClinicalIndex();
  }

  Future<void> _createSearchSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_entries (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        normalized_name TEXT NOT NULL,
        is_benchmark INTEGER NOT NULL DEFAULT 0
          CHECK (is_benchmark IN (0, 1)),
        data_json TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS search_entries_exact_idx '
      'ON search_entries(normalized_name, is_benchmark)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS search_entries_prefix_idx '
      'ON search_entries(normalized_name)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_grams (
        entry_id TEXT NOT NULL,
        gram TEXT NOT NULL,
        PRIMARY KEY (entry_id, gram)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS search_grams_lookup_idx '
      'ON search_grams(gram, entry_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_gram_frequencies (
        gram TEXT NOT NULL,
        is_benchmark INTEGER NOT NULL,
        frequency INTEGER NOT NULL,
        PRIMARY KEY (gram, is_benchmark)
      )
    ''');
  }

  Future<void> refreshClinicalIndex() async {
    final db = await _databaseService.database;
    await _createSearchSchema(db);
    final drugs = await _databaseService.getDrugs();
    await db.transaction((transaction) async {
      await transaction.delete(
        'search_grams',
        where: 'entry_id IN (SELECT id FROM search_entries WHERE is_benchmark = 0)',
      );
      await transaction.delete('search_entries', where: 'is_benchmark = 0');
      final entries = transaction.batch();
      final grams = transaction.batch();
      for (final drug in drugs) {
        final id = 'clinical:${drug.id}';
        entries.insert('search_entries', {
          'id': id,
          'name': drug.name,
          'normalized_name': _normalize(drug.name),
          'is_benchmark': 0,
          'data_json': jsonEncode(_drugData(drug)),
        });
        for (final gram in _grams(_normalize(drug.name))) {
          grams.insert('search_grams', {'entry_id': id, 'gram': gram});
        }
      }
      await entries.commit(noResult: true);
      await grams.commit(noResult: true);
      await _rebuildGramFrequencies(transaction);
    });
  }

  Future<void> seedBenchmarkEntries({
    int count = defaultBenchmarkEntryCount,
  }) async {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Must not be negative.');
    }
    final db = await _databaseService.database;
    await _createSearchSchema(db);
    await db.transaction((transaction) async {
      await transaction.delete(
        'search_grams',
        where: 'entry_id IN (SELECT id FROM search_entries WHERE is_benchmark = 1)',
      );
      await transaction.delete('search_entries', where: 'is_benchmark = 1');

      for (var offset = 0; offset < count; offset += _seedBatchSize) {
        final entries = transaction.batch();
        final grams = transaction.batch();
        final end = math.min(offset + _seedBatchSize, count);
        for (var index = offset; index < end; index++) {
          final number = (index + 1).toString().padLeft(5, '0');
          final id = 'benchmark:$number';
          final name = 'Benchmark Mock Drug $number';
          final normalizedName = _normalize(name);
          final data = <String, dynamic>{
            'id': id,
            'name': name,
            'concentration': '1 mg/mL',
            'route': 'BENCHMARK',
            'is_benchmark': true,
          };
          entries.insert('search_entries', {
            'id': id,
            'name': name,
            'normalized_name': normalizedName,
            'is_benchmark': 1,
            'data_json': jsonEncode(data),
          });
          for (final gram in _grams(normalizedName)) {
            grams.insert('search_grams', {'entry_id': id, 'gram': gram});
          }
        }
        await entries.commit(noResult: true);
        await grams.commit(noResult: true);
        await Future<void>.delayed(Duration.zero);
      }
      await _rebuildGramFrequencies(transaction);
    });
  }

  Future<int> benchmarkEntryCount() async {
    await initialize();
    final db = await _databaseService.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM search_entries WHERE is_benchmark = 1',
    );
    return result.single['count']! as int;
  }

  Future<List<DrugSearchResult>> search(
    String query, {
    int limit = 20,
    bool includeBenchmark = false,
    SearchCancellationToken? cancellationToken,
  }) async {
    final generation = ++_requestGeneration;
    await initialize();
    final stopwatch = Stopwatch()..start();
    try {
      if (limit <= 0) {
        throw ArgumentError.value(limit, 'limit', 'Must be greater than zero.');
      }
      _ensureNotCancelled(generation, cancellationToken);
      final normalized = _normalize(query);
      if (normalized.isEmpty) return const [];

      final db = await _databaseService.database;
      final benchmarkFilter = includeBenchmark ? '' : 'AND is_benchmark = 0';
      final benchmarkJoinFilter = includeBenchmark
          ? ''
          : 'AND e.is_benchmark = 0';
      final exactRows = await db.rawQuery(
        'SELECT * FROM search_entries '
        'WHERE normalized_name = ? $benchmarkFilter LIMIT ?',
        [normalized, limit],
      );
      _ensureNotCancelled(generation, cancellationToken);
      final results = <DrugSearchResult>[
        for (final row in exactRows) _resultFromRow(row, SearchMatchType.exact),
      ];
      if (results.length < limit) {
        final prefixRows = await db.rawQuery(
          'SELECT * FROM search_entries '
          'WHERE normalized_name >= ? AND normalized_name < ? '
          'AND normalized_name != ? $benchmarkFilter '
          'ORDER BY normalized_name LIMIT ?',
          [normalized, '$normalized\uFFFF', normalized, limit - results.length],
        );
        _ensureNotCancelled(generation, cancellationToken);
        results.addAll(
          prefixRows.map((row) => _resultFromRow(row, SearchMatchType.prefix)),
        );
      }

      if (results.isEmpty &&
          normalized.length >= 4 &&
          !normalized.contains(' ')) {
        final grams = _grams(normalized).toList();
        final placeholders = List.filled(grams.length, '?').join(',');
        final rareGramRows = await db.rawQuery(
          '''
          SELECT gram, frequency
          FROM search_gram_frequencies
          WHERE gram IN ($placeholders) AND is_benchmark = ?
          ORDER BY frequency ASC
          LIMIT 8
          ''',
          [...grams, includeBenchmark ? 1 : 0],
        );
        _ensureNotCancelled(generation, cancellationToken);
        if (rareGramRows.isNotEmpty && results.isEmpty) {
          final rareGrams = rareGramRows
              .map((row) => row['gram']! as String)
              .toList(growable: false);
          final rarePlaceholders = List.filled(rareGrams.length, '?').join(',');
          final fuzzyRows = await db.rawQuery(
            '''
          SELECT e.*, COUNT(*) AS shared_grams
          FROM search_grams g
          JOIN search_entries e ON e.id = g.entry_id
          WHERE g.gram IN ($rarePlaceholders) $benchmarkJoinFilter
          GROUP BY e.id
          ORDER BY shared_grams DESC
          LIMIT ?
          ''',
            [...rareGrams, _maxFuzzyCandidates],
          );
          _ensureNotCancelled(generation, cancellationToken);

          final fuzzy =
              <({DrugSearchResult result, int distance, int overlap})>[];
          for (final row in fuzzyRows) {
            final candidate = row['normalized_name']! as String;
            if (candidate == normalized || candidate.startsWith(normalized)) {
              continue;
            }
            final distance = _levenshtein(normalized, candidate);
            final threshold = normalized.length >= 7 ? 2 : 1;
            if (distance <= threshold) {
              fuzzy.add((
                result: _resultFromRow(row, SearchMatchType.approximate),
                distance: distance,
                overlap: row['shared_grams']! as int,
              ));
            }
          }
          fuzzy.sort((first, second) {
            final distanceOrder = first.distance.compareTo(second.distance);
            if (distanceOrder != 0) return distanceOrder;
            final overlapOrder = second.overlap.compareTo(first.overlap);
            return overlapOrder != 0
                ? overlapOrder
                : first.result.name.compareTo(second.result.name);
          });
          results.addAll(
            fuzzy.take(limit - results.length).map((match) => match.result),
          );
        }
      }

      _ensureNotCancelled(generation, cancellationToken);
      return List.unmodifiable(results);
    } finally {
      stopwatch.stop();
      _recordLatency(stopwatch.elapsed);
    }
  }

  SearchPerformanceReport get performanceReport {
    if (_latencies.isEmpty) {
      return const SearchPerformanceReport(
        sampleCount: 0,
        typicalLatency: Duration.zero,
        worstCaseLatency: Duration.zero,
      );
    }
    final samples = _latencies.toList()..sort();
    return SearchPerformanceReport(
      sampleCount: samples.length,
      typicalLatency: samples[samples.length ~/ 2],
      worstCaseLatency: samples.last,
    );
  }

  Future<void> clearBenchmarkEntries() async {
    await initialize();
    final db = await _databaseService.database;
    await db.transaction((transaction) async {
      await transaction.delete(
        'search_grams',
        where: 'entry_id IN (SELECT id FROM search_entries WHERE is_benchmark = 1)',
      );
      await transaction.delete('search_entries', where: 'is_benchmark = 1');
      await _rebuildGramFrequencies(transaction);
    });
  }

  void _ensureNotCancelled(
    int generation,
    SearchCancellationToken? cancellationToken,
  ) {
    if (cancellationToken?.isCancelled == true ||
        generation != _requestGeneration) {
      throw const SearchCancelledException();
    }
  }

  DrugSearchResult _resultFromRow(
    Map<String, Object?> row,
    SearchMatchType matchType,
  ) {
    final data =
        jsonDecode(row['data_json']! as String) as Map<String, dynamic>;
    return DrugSearchResult(
      id: data['id']?.toString() ?? row['id']! as String,
      name: row['name']! as String,
      isBenchmark: row['is_benchmark']! as int == 1,
      matchType: matchType,
      data: data,
    );
  }

  Future<void> _rebuildGramFrequencies(Transaction transaction) async {
    await transaction.delete('search_gram_frequencies');
    await transaction.execute('''
      INSERT INTO search_gram_frequencies (gram, is_benchmark, frequency)
      SELECT grams.gram, entries.is_benchmark, COUNT(*)
      FROM search_grams AS grams
      JOIN search_entries AS entries ON entries.id = grams.entry_id
      GROUP BY grams.gram, entries.is_benchmark
    ''');
  }

  Map<String, dynamic> _drugData(Drug drug) => {
    'id': drug.id,
    'name': drug.name,
    'concentration': drug.concentration,
    'route': drug.route,
    'doses': {
      for (final entry in drug.doses.entries)
        entry.key: {
          'min': entry.value.min,
          'max': entry.value.max,
          'unit': entry.value.unit,
        },
    },
    'cri_ranges': [
      for (final range in drug.criRanges)
        {
          'min': range.min,
          'max': range.max,
          'unit': range.unit,
          if (range.species != null) 'species': range.species,
        },
    ],
    if (drug.maxTotalMg != null) 'max_total_mg': drug.maxTotalMg,
    'is_withdrawn': drug.isWithdrawn,
  };

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  Set<String> _grams(String value) {
    final compact = value.replaceAll(' ', '');
    if (compact.length < 3) return {compact};
    return {
      for (var index = 0; index < compact.length - 2; index++)
        compact.substring(index, index + 3),
    };
  }

  int _levenshtein(String first, String second) {
    if (first == second) return 0;
    if (first.isEmpty) return second.length;
    if (second.isEmpty) return first.length;
    if (first.length > second.length) {
      final swap = first;
      first = second;
      second = swap;
    }

    var previous = List<int>.generate(first.length + 1, (index) => index);
    for (var row = 1; row <= second.length; row++) {
      final current = List<int>.filled(first.length + 1, 0);
      current[0] = row;
      for (var column = 1; column <= first.length; column++) {
        final substitutionCost =
            first.codeUnitAt(column - 1) == second.codeUnitAt(row - 1) ? 0 : 1;
        current[column] = math.min(
          math.min(current[column - 1] + 1, previous[column] + 1),
          previous[column - 1] + substitutionCost,
        );
      }
      previous = current;
    }
    return previous[first.length];
  }

  void _recordLatency(Duration latency) {
    _latencies.addLast(latency);
    if (_latencies.length > _maxLatencySamples) {
      _latencies.removeFirst();
    }
  }
}
