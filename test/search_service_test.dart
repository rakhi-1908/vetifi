import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vetifi/services/database_service.dart';
import 'package:vetifi/services/search_service.dart';

const _seed = '''
{
  "schema version": 2,
  "dataset version": "v14",
  "drugs": [
    {
      "id": "d004",
      "name": "Meloquin",
      "concentration": "1.5 mg/mL",
      "route": "PO",
      "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"}}
    },
    {
      "id": "d007",
      "name": "Benzaprol",
      "concentration": "10%",
      "route": "IV",
      "doses": {"dog": {"min": 2, "max": 5, "unit": "mg/kg"}}
    },
    {
      "id": "d011",
      "name": "Meloquin XR",
      "concentration": "2 mg/mL",
      "route": "PO",
      "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"}}
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'ranks exact matches before prefixes and typo-tolerant matches',
    () async {
      final database = _databaseService();
      final search = SearchService(databaseService: database);
      await search.initialize();

      final exact = await search.search('Meloquin');
      expect(exact.first.id, 'd004');
      expect(exact.first.matchType, SearchMatchType.exact);
      expect(exact[1].name, 'Meloquin XR');
      expect(exact[1].matchType, SearchMatchType.prefix);

      final prefix = await search.search('Melo');
      expect(prefix.first.name, 'Meloquin');
      expect(prefix.first.matchType, SearchMatchType.prefix);

      final typoMeloquin = await search.search('melokin');
      expect(typoMeloquin, isNotEmpty);
      expect(typoMeloquin.first.name, 'Meloquin');
      expect(typoMeloquin.first.matchType, SearchMatchType.approximate);

      final typoBenzaprol = await search.search('benzaprl');
      expect(typoBenzaprol, isNotEmpty);
      expect(typoBenzaprol.first.name, 'Benzaprol');
      expect(typoBenzaprol.first.matchType, SearchMatchType.approximate);

      await database.close();
    },
  );

  test('seeds 50,000 benchmark-only entries and isolates normal results', () async {
    final database = _databaseService();
    final search = SearchService(databaseService: database);
    await search.initialize(seedBenchmarkData: true);

    expect(await search.benchmarkEntryCount(), 50000);
    final ordinaryResults = await search.search('Benchmark Mock Drug 49999');
    expect(ordinaryResults, isEmpty);

    final benchmarkResults = await search.search(
      'Benchmark Mock Drug 49999',
      includeBenchmark: true,
      limit: 1,
    );
    expect(benchmarkResults, hasLength(1));
    expect(benchmarkResults.single.id, 'benchmark:49999');
    expect(benchmarkResults.single.isBenchmark, isTrue);
    expect(benchmarkResults.single.drug, isNull);

    final report = search.performanceReport;
    final queryLatencies = <String, int>{};
    for (final query in [
      'Benchmark',
      'Mock Drug',
      'Benchmark Mock',
      'benchmark mock drug 00001',
      'benchmark mock drug 25000',
      'benchmark mock drug 49999',
      'benchmark mock dru 49999',
      'Benchmark Mock Drug 50000',
    ]) {
      final stopwatch = Stopwatch()..start();
      await search.search(query, includeBenchmark: true);
      stopwatch.stop();
      queryLatencies[query] = stopwatch.elapsed.inMicroseconds;
    }
    final measuredReport = search.performanceReport;
    expect(measuredReport.sampleCount, 10);
    expect(
      measuredReport.typicalLatency,
      lessThanOrEqualTo(measuredReport.worstCaseLatency),
    );
    // Reports query-time latency after index initialization, not seed time.
    // ignore: avoid_print
    print(
      '50,000-entry search latency: typical='
      '${measuredReport.typicalLatency.inMicroseconds}us, worst='
      '${measuredReport.worstCaseLatency.inMicroseconds}us, queries=$queryLatencies',
    );
    expect(report.sampleCount, 2);
    expect(report.typicalLatency, lessThanOrEqualTo(report.worstCaseLatency));

    await database.close();
  });

  test(
    'cancels a superseded search instead of returning stale results',
    () async {
      final database = _databaseService();
      final search = SearchService(databaseService: database);
      await search.initialize();

      final oldToken = SearchCancellationToken();
      final oldSearch = search.search('melokin', cancellationToken: oldToken);
      final newestSearch = search.search('Benzaprol');
      oldToken.cancel();

      await expectLater(oldSearch, throwsA(isA<SearchCancelledException>()));
      final currentResults = await newestSearch;
      expect(currentResults.first.name, 'Benzaprol');
      expect(currentResults.first.matchType, SearchMatchType.exact);

      await database.close();
    },
  );

  test('records typical and worst-case query latency samples', () async {
    final database = _databaseService();
    final search = SearchService(databaseService: database);
    await search.initialize();

    await search.search('Melo');
    await search.search('melokin');
    await search.search('benzaprl');
    final report = search.performanceReport;

    expect(report.sampleCount, 3);
    expect(report.typicalLatency, greaterThanOrEqualTo(Duration.zero));
    expect(
      report.worstCaseLatency,
      greaterThanOrEqualTo(report.typicalLatency),
    );
    await database.close();
  });
}

DatabaseService _databaseService() => DatabaseService(
  databasePath: inMemoryDatabasePath,
  initialDatasetJson: _seed,
);
