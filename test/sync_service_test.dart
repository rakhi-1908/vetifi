import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vetifi/services/database_service.dart';
import 'package:vetifi/services/sync_service.dart';

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
    'verifies signed manifest and snapshot before applying update',
    () async {
      final fixture = await _signedFixture();
      final database = _newDatabaseService();
      final responses = <SyncHttpResponse>[
        SyncHttpResponse(statusCode: 200, body: jsonEncode(fixture.manifest)),
        SyncHttpResponse(statusCode: 200, body: jsonEncode(fixture.dataset)),
      ];
      final requestedUris = <Uri>[];
      final service = SyncService(
        databaseService: database,
        apiBaseUri: Uri.parse('https://api.example.test'),
        isOnline: () async => true,
        trustedPublicKeyHex: fixture.publicKeyHex,
        httpGet: (uri) async {
          requestedUris.add(uri);
          return responses.removeAt(0);
        },
      );

      final result = await service.synchronize();
      expect(result.status, SyncStatus.updated);
      expect(result.version, 'v15');
      expect(await database.getDatasetVersion(), 'v15');
      expect((await database.getDrugs()).single.name, 'Updated Veloxamine');
      expect(requestedUris, hasLength(2));
      expect(requestedUris.first.path, '/v1/manifest');
      expect(requestedUris.first.queryParameters['current'], 'v14');
      expect(requestedUris.last.path, '/v1/datasets/v15');
      expect(requestedUris.last.queryParameters['from'], isNull);

      await database.close();
    },
  );

  test(
    'rejects modified signed data without changing the local dataset',
    () async {
      final fixture = await _signedFixture();
      final tamperedDataset =
          jsonDecode(jsonEncode(fixture.dataset)) as Map<String, dynamic>;
      (tamperedDataset['payload'] as Map<String, dynamic>)['drugs'][0]['name'] =
          'Tampered';
      final database = _newDatabaseService();
      var requestIndex = 0;
      final responses = [
        SyncHttpResponse(statusCode: 200, body: jsonEncode(fixture.manifest)),
        SyncHttpResponse(statusCode: 200, body: jsonEncode(tamperedDataset)),
      ];
      final service = SyncService(
        databaseService: database,
        apiBaseUri: Uri.parse('https://api.example.test'),
        isOnline: () async => true,
        trustedPublicKeyHex: fixture.publicKeyHex,
        httpGet: (_) async => responses[requestIndex++],
      );

      final result = await service.synchronize();
      expect(result.status, SyncStatus.rejected);
      expect(await database.getDatasetVersion(), 'v14');
      expect((await database.getDrugs()).single.name, 'Veloxamine');

      await database.close();
    },
  );

  test(
    'rejects a bad checksum and truncated response without applying it',
    () async {
      final fixture = await _signedFixture();
      final badChecksumDataset = Map<String, dynamic>.from(fixture.dataset);
      badChecksumDataset['sha256'] = '0' * 64;
      badChecksumDataset['signature'] = await _sign(
        fixture.keyPair,
        _withoutSignature(badChecksumDataset),
      );

      for (final datasetBody in [
        jsonEncode(badChecksumDataset),
        '{"schema_version":2,"dataset_version":"v15"',
      ]) {
        final database = _newDatabaseService();
        var requestIndex = 0;
        final responses = [
          SyncHttpResponse(statusCode: 200, body: jsonEncode(fixture.manifest)),
          SyncHttpResponse(statusCode: 200, body: datasetBody),
        ];
        final service = SyncService(
          databaseService: database,
          apiBaseUri: Uri.parse('https://api.example.test'),
          isOnline: () async => true,
          trustedPublicKeyHex: fixture.publicKeyHex,
          httpGet: (_) async => responses[requestIndex++],
        );

        final result = await service.synchronize();
        expect(result.status, SyncStatus.rejected);
        expect(await database.getDatasetVersion(), 'v14');
        expect((await database.getDrugs()).single.name, 'Veloxamine');
        await database.close();
      }
    },
  );

  test('does not make requests while offline', () async {
    final database = _newDatabaseService();
    var requestCount = 0;
    final service = SyncService(
      databaseService: database,
      apiBaseUri: Uri.parse('https://api.example.test'),
      isOnline: () async => false,
      httpGet: (_) async {
        requestCount++;
        throw StateError('Should not be called while offline.');
      },
    );

    expect((await service.synchronize()).status, SyncStatus.offline);
    expect(requestCount, 0);
    expect(await database.getDatasetVersion(), 'v14');
    await database.close();
  });

  test('uploads queued calculation logs only while online', () async {
    final uploadedKeys = <String>[];
    final database = _newDatabaseService(
      calculationLogUploader: (endpoint, idempotencyKey, payload) async {
        expect(endpoint.path, '/v1/calc_logs');
        expect(jsonDecode(payload), contains('dataset_version'));
        uploadedKeys.add(idempotencyKey);
      },
    );
    final key = await database.saveCalculationLog(
      inputs: {'weight_kg': 4.5},
      result: {'dose_ml': 0.9},
      datasetVersion: 'v14',
    );
    final service = SyncService(
      databaseService: database,
      apiBaseUri: Uri.parse('https://api.example.test'),
      isOnline: () async => true,
      httpGet: (_) async => throw StateError('No dataset request expected.'),
    );

    expect(await service.syncPendingCalculationLogs(), 1);
    expect(uploadedKeys, [key]);
    expect(await database.getPendingCalculationLogs(), isEmpty);
    await database.close();
  });

  test('does not upload queued calculation logs while offline', () async {
    final database = _newDatabaseService(
      calculationLogUploader: (_, _, _) async {
        fail('Calculation log upload should not run while offline.');
      },
    );
    await database.saveCalculationLog(
      inputs: {'weight_kg': 4.5},
      result: {'dose_ml': 0.9},
      datasetVersion: 'v14',
    );
    final service = SyncService(
      databaseService: database,
      apiBaseUri: Uri.parse('https://api.example.test'),
      isOnline: () async => false,
      httpGet: (_) async => throw StateError('No request expected offline.'),
    );

    expect(await service.syncPendingCalculationLogs(), 0);
    expect(await database.getPendingCalculationLogs(), hasLength(1));
    await database.close();
  });
}

DatabaseService _newDatabaseService({
  CalculationLogUploader? calculationLogUploader,
}) => DatabaseService(
  databasePath: inMemoryDatabasePath,
  initialDatasetJson: _seed,
  calculationLogUploader: calculationLogUploader,
);

Future<_SignedFixture> _signedFixture() async {
  final keyPair = await Ed25519().newKeyPairFromSeed(
    List<int>.generate(32, (index) => index + 1),
  );
  final publicKey = await keyPair.extractPublicKey();
  final publicKeyHex = _toHex(publicKey.bytes);
  final snapshot = <String, dynamic>{
    'schema_version': 2,
    'dataset_version': 'v15',
    'base_version': 'v14',
    'drugs': [
      {
        'id': 'd001',
        'name': 'Updated Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'},
        },
      },
    ],
  };
  final snapshotHash = await _sha256(snapshot);
  final manifest = <String, dynamic>{
    'schema_version': 2,
    'latest_version': 'v15',
    'delta_available': false,
    'payload_size': utf8.encode(_canonicalJson(snapshot)).length,
    'sha256': snapshotHash,
    'public_key': publicKeyHex,
  };
  manifest['signature'] = await _sign(keyPair, manifest);

  final dataset = <String, dynamic>{
    'schema_version': 2,
    'dataset_version': 'v15',
    'base_version': 'v14',
    'payload': snapshot,
    'sha256': snapshotHash,
    'public_key': publicKeyHex,
  };
  dataset['signature'] = await _sign(keyPair, dataset);
  return _SignedFixture(
    keyPair: keyPair,
    publicKeyHex: publicKeyHex,
    manifest: manifest,
    dataset: dataset,
  );
}

Map<String, dynamic> _withoutSignature(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(value)..remove('signature');

Future<String> _sign(SimpleKeyPair keyPair, Map<String, dynamic> value) async {
  final signature = await Ed25519().sign(
    utf8.encode(_canonicalJson(value)),
    keyPair: keyPair,
  );
  return base64Encode(signature.bytes);
}

Future<String> _sha256(Object value) async {
  final digest = await Sha256().hash(utf8.encode(_canonicalJson(value)));
  return _toHex(digest.bytes);
}

String _canonicalJson(Object? value) {
  Object? canonicalize(Object? input) {
    if (input is Map) {
      final keys = input.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: canonicalize(input[key]),
      };
    }
    if (input is List) return input.map(canonicalize).toList();
    return input;
  }

  return jsonEncode(canonicalize(value));
}

String _toHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class _SignedFixture {
  const _SignedFixture({
    required this.keyPair,
    required this.publicKeyHex,
    required this.manifest,
    required this.dataset,
  });

  final SimpleKeyPair keyPair;
  final String publicKeyHex;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> dataset;
}
