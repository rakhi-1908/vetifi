// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:vetifi/main.dart';
import 'package:vetifi/models/drug_model.dart';
import 'package:vetifi/services/database_service.dart';
import 'package:vetifi/services/search_service.dart';

const _seedDataset = '''
{
  "schema version": 2,
  "dataset version": "v14",
  "drugs": [
    {
      "id": "d001",
      "name": "Veloxamine",
      "concentration": "50 mg/mL",
      "route": "IV",
      "doses": {"dog": {"min": 5, "max": 10, "unit": "mg/kg"}}
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('VetifiApp opens the local clinical drug search', (
    WidgetTester tester,
  ) async {
    final databaseService = DatabaseService(
      databasePath: inMemoryDatabasePath,
      initialDatasetJson: _seedDataset,
    );
    await tester.pumpWidget(
      VetifiApp(databaseService: databaseService, enableBackgroundSync: false),
    );
    await tester.pump();

    expect(find.text('Vetifi'), findsOneWidget);
    expect(find.text('Clinical drug search'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(databaseService.close);
  });

  testWidgets('drug results are tappable and open drug dose details', (
    WidgetTester tester,
  ) async {
    const drug = Drug(
      id: 'd001',
      name: 'Veloxamine',
      concentration: '50 mg/mL',
      route: 'IV',
      doses: {'dog': DoseRange(min: 5, max: 10, unit: 'mg/kg')},
      criRanges: [],
      maxTotalMg: null,
      isWithdrawn: false,
    );
    final searchResult = DrugSearchResult(
      id: drug.id,
      name: drug.name,
      isBenchmark: false,
      matchType: SearchMatchType.exact,
      data: {
        'id': drug.id,
        'name': drug.name,
        'concentration': drug.concentration,
        'route': drug.route,
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => DrugResultCard(
              result: searchResult,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => const DrugDetailsScreen(drug: drug),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ListTile));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Dose ranges'), findsOneWidget);
    expect(find.text('Dog'), findsOneWidget);
    expect(find.text('5–10 mg/kg'), findsOneWidget);
  });
}
