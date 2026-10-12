import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vetifi/services/database_service.dart';

const _seed = '''
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
    },
    {
      "id": "d002",
      "name": "Tranzorel",
      "concentration": "1 mg/mL",
      "route": "IM",
      "doses": {"dog": {"min": 10, "max": 20, "unit": "mcg/kg"}}
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

  DatabaseService createService({
    CalculationLogUploader? calculationLogUploader,
  }) => DatabaseService(
    databasePath: inMemoryDatabasePath,
    initialDatasetJson: _seed,
    calculationLogUploader: calculationLogUploader,
  );

  test('seeds v14 locally on first open', () async {
    final service = createService();
    expect(await service.getDatasetVersion(), 'v14');
    final drugs = await service.getDrugs();
    expect(drugs.map((drug) => drug.id), containsAll(['d001', 'd002']));
    await service.close();
  });

  test('bundles the complete initial v14 dataset', () async {
    final service = DatabaseService(databasePath: inMemoryDatabasePath);
    expect(await service.getDatasetVersion(), 'v14');
    expect(await service.getDrugs(), hasLength(10));
    await service.close();
  });

  test('applies a full snapshot and a delta atomically', () async {
    final service = createService();
    await service.database;

    await service.applyUpdate({
      'schema_version': 2,
      'dataset_version': 'v15',
      'payload': {
        'schema_version': 2,
        'dataset_version': 'v15',
        'drugs': [
          {
            'id': 'd001',
            'name': 'Veloxamine Updated',
            'concentration': '50 mg/mL',
            'route': 'IV',
            'doses': {
              'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'},
            },
          },
        ],
      },
    });
    expect(await service.getDatasetVersion(), 'v15');
    expect((await service.getDrugs()).single.name, 'Veloxamine Updated');

    await service.applyUpdate({
      'schema_version': 2,
      'dataset_version': 'v16',
      'base_version': 'v15',
      'delta': {
        'upsert': [
          {
            'id': 'd003',
            'name': 'New drug',
            'concentration': '2 mg/mL',
            'route': 'PO',
            'doses': <String, dynamic>{},
          },
        ],
        'delete': ['d001'],
      },
    });
    expect(await service.getDatasetVersion(), 'v16');
    expect((await service.getDrugs()).map((drug) => drug.id), ['d003']);
    await service.close();
  });

  test(
    'failed transaction leaves the old version and all drugs intact',
    () async {
      final service = createService();
      await service.database;
      final before = await service.getDrugs();

      await expectLater(
        service.applyUpdate({
          'schema_version': 2,
          'dataset_version': 'v15',
          'drugs': [
            {
              'id': 'd003',
              'name': 'Valid until serialization',
              'concentration': '1 mg/mL',
              'route': 'IV',
              'doses': <String, dynamic>{},
              'unsupported': Object(),
            },
          ],
        }),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );

      expect(await service.getDatasetVersion(), 'v14');
      expect(
        (await service.getDrugs()).map((drug) => drug.id),
        before.map((drug) => drug.id),
      );
      await service.close();
    },
  );

  test(
    'rejects a delta with a stale base without changing local data',
    () async {
      final service = createService();
      await service.database;

      await expectLater(
        service.applyUpdate({
          'schema_version': 2,
          'dataset_version': 'v15',
          'base_version': 'v13',
          'delta': {'upsert': [], 'delete': []},
        }),
        throwsStateError,
      );

      expect(await service.getDatasetVersion(), 'v14');
      expect((await service.getDrugs()).length, 2);
      await service.close();
    },
  );

  test(
    'saves calculation logs locally and uploads the queue on demand',
    () async {
      var uploadCalls = 0;
      final service = createService(
        calculationLogUploader: (endpoint, idempotencyKey, payload) async {
          uploadCalls++;
          expect(endpoint.path, '/v1/calc_logs');
          expect(idempotencyKey, 'calc-001');
          expect(jsonDecode(payload)['dataset_version'], 'v14');
        },
      );
      final key = await service.saveCalculationLog(
        inputs: {'drug_id': 'd001', 'weight_kg': 10},
        result: {'dose_mg': 50},
        datasetVersion: 'v14',
        idempotencyKey: 'calc-001',
      );

      expect(key, 'calc-001');
      expect(uploadCalls, 0);
      expect(await service.getPendingCalculationLogs(), [
        {
          'idempotency_key': 'calc-001',
          'inputs': {'drug_id': 'd001', 'weight_kg': 10},
          'result': {'dose_mg': 50},
          'dataset_version': 'v14',
        },
      ]);

      final uploaded = await service.flushPendingLogs(
        Uri.parse('https://api.example.test/v1/calc_logs'),
      );
      expect(uploaded, 1);
      expect(await service.getPendingCalculationLogs(), isEmpty);
      expect(uploadCalls, 1);

      await service.close();
    },
  );
}
