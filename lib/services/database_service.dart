import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/drug_model.dart';

typedef CalculationLogUploader = Future<void> Function(
  Uri endpoint,
  String idempotencyKey,
  String payload,
);

class DatabaseService {
  DatabaseService({
    this.databasePath,
    this.initialDatasetJson,
    Connectivity? connectivity,
    this.calculationLogUploader,
  }) : _connectivity = connectivity ?? Connectivity();

  static const int _databaseVersion = 1;
  static const String _seedAssetPath = 'assets/data/dataset_v14.json';
  static const String _seedVersion = 'v14';

  final String? databasePath;
  final String? initialDatasetJson;
  final Connectivity _connectivity;
  final CalculationLogUploader? calculationLogUploader;
  Database? _database;
  Future<Database>? _openingDatabase;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Future<void>? _activeSync;

  Future<Database> get database async {
    final openDatabase = _database;
    if (openDatabase != null && openDatabase.isOpen) return openDatabase;
    return _openingDatabase ??= _openDatabase();
  }

  Future<Database> _openDatabase() async {
    try {
      final path = databasePath ?? await _defaultDatabasePath();
      final db = await openDatabase(
        path,
        version: _databaseVersion,
        onCreate: (database, version) async {
          await _createSchema(database);
        },
      );
      _database = db;
      await _seedIfNeeded(db);
      return db;
    } catch (_) {
      _openingDatabase = null;
      rethrow;
    }
  }

  Future<String> _defaultDatabasePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}${Platform.pathSeparator}vetifi.db';
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE drugs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        concentration TEXT NOT NULL,
        route TEXT NOT NULL,
        data_json TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE app_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE calculation_logs (
        id TEXT PRIMARY KEY,
        inputs_json TEXT NOT NULL,
        result_json TEXT NOT NULL,
        dataset_version TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'uploaded')),
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX calculation_logs_pending_idx '
      'ON calculation_logs(status, created_at)',
    );
  }

  Future<void> _seedIfNeeded(Database db) async {
    final version = await _getMetadata(db, 'dataset_version');
    if (version != null) return;

    final source =
        initialDatasetJson ?? await rootBundle.loadString(_seedAssetPath);
    final seed = _decodeObject(source, 'bundled seed dataset');
    final seedVersion = _datasetVersion(seed);
    if (seedVersion != _seedVersion) {
      throw FormatException('Bundled dataset must be $_seedVersion.');
    }
    final drugs = _extractDrugs(seed);
    await db.transaction((transaction) async {
      final storedVersion = await _getMetadata(transaction, 'dataset_version');
      if (storedVersion != null) return;
      await _replaceDrugs(transaction, drugs);
      await _setMetadata(transaction, 'dataset_version', seedVersion);
      await _setMetadata(
        transaction,
        'schema_version',
        _schemaVersion(seed).toString(),
      );
    });
  }

  Future<void> applyUpdate(Map<String, dynamic> payload) async {
    final newVersion = _datasetVersion(payload);
    final schemaVersion = _schemaVersion(payload);
    if (schemaVersion != 2) {
      throw FormatException(
        'Unsupported dataset schema version: $schemaVersion',
      );
    }

    final deltaValue = payload['delta'];
    final isDelta = deltaValue is Map;
    final snapshot = payload['payload'] is Map
        ? Map<String, dynamic>.from(payload['payload'] as Map)
        : payload;
    final db = await database;

    await db.transaction((transaction) async {
      final currentVersion = await _getMetadata(transaction, 'dataset_version');

      if (isDelta) {
        final baseVersion = payload['base_version']?.toString();
        if (baseVersion == null || currentVersion != baseVersion) {
          throw StateError(
            'Delta base version $baseVersion does not match local version '
            '$currentVersion.',
          );
        }
        final delta = Map<String, dynamic>.from(deltaValue);
        final deleteIds = delta['delete'];
        final upserts = delta['upsert'];
        if (deleteIds is! List || upserts is! List) {
          throw const FormatException(
            'Delta must contain upsert and delete lists.',
          );
        }
        for (final id in deleteIds) {
          await transaction.delete(
            'drugs',
            where: 'id = ?',
            whereArgs: [id.toString()],
          );
        }
        for (final rawDrug in upserts) {
          if (rawDrug is! Map) {
            throw const FormatException(
              'Every delta upsert must be a drug object.',
            );
          }
          await _upsertDrug(transaction, Map<String, dynamic>.from(rawDrug));
        }
      } else {
        if (currentVersion == null) {
          throw StateError(
            'Cannot apply a dataset update before local seeding.',
          );
        }
        final drugs = _extractDrugs(snapshot);
        await _replaceDrugs(transaction, drugs);
      }

      await _setMetadata(transaction, 'dataset_version', newVersion);
      await _setMetadata(
        transaction,
        'schema_version',
        schemaVersion.toString(),
      );
    });
  }

  Future<List<Drug>> getDrugs() async {
    final db = await database;
    final rows = await db.query('drugs', orderBy: 'name COLLATE NOCASE, id');
    return rows
        .map(
          (row) => Drug.fromJson(
            jsonDecode(row['data_json']! as String) as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  Future<String?> getDatasetVersion() async {
    final db = await database;
    return _getMetadata(db, 'dataset_version');
  }

  /// Persists calculation data locally; this method never performs network I/O.
  Future<String> saveCalculationLog({
    required Map<String, dynamic> inputs,
    required Map<String, dynamic> result,
    required String datasetVersion,
    String? idempotencyKey,
  }) async {
    if (datasetVersion.trim().isEmpty) {
      throw ArgumentError.value(
        datasetVersion,
        'datasetVersion',
        'Dataset version must not be empty.',
      );
    }
    final key = idempotencyKey ?? _newIdempotencyKey();
    final payload = <String, dynamic>{
      'idempotency_key': key,
      'inputs': inputs,
      'result': result,
      'dataset_version': datasetVersion,
    };
    final db = await database;
    await db.insert('calculation_logs', {
      'id': key,
      'inputs_json': jsonEncode(inputs),
      'result_json': jsonEncode(result),
      'dataset_version': datasetVersion,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.abort);
    return key;
  }

  Future<List<Map<String, dynamic>>> getPendingCalculationLogs() async {
    final db = await database;
    final rows = await db.query(
      'calculation_logs',
      columns: ['payload_json'],
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at, id',
    );
    return rows
        .map(
          (row) =>
              jsonDecode(row['payload_json']! as String)
                  as Map<String, dynamic>,
        )
        .toList(growable: false);
  }

  /// Uploads pending logs only when explicitly invoked by the sync path.
  /// Successful rows are marked uploaded; failed requests remain pending.
  Future<int> flushPendingLogs(Uri endpoint) async {
    final active = _activeSync;
    if (active != null) {
      await active;
      return 0;
    }
    final sync = _flushPendingLogs(endpoint);
    _activeSync = sync;
    try {
      return await sync;
    } finally {
      _activeSync = null;
    }
  }

  Future<int> _flushPendingLogs(Uri endpoint) async {
    final db = await database;
    final rows = await db.query(
      'calculation_logs',
      columns: ['id', 'payload_json', 'attempts'],
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at, id',
    );
    var uploadedCount = 0;
    for (final row in rows) {
      final id = row['id']! as String;
      try {
        await _uploadCalculationLog(
          endpoint,
          id,
          row['payload_json']! as String,
        );
        await db.update(
          'calculation_logs',
          {'status': 'uploaded', 'last_error': null},
          where: 'id = ?',
          whereArgs: [id],
        );
        uploadedCount++;
      } catch (error) {
        await db.update(
          'calculation_logs',
          {
            'attempts': (row['attempts']! as int) + 1,
            'last_error': error.toString(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        rethrow;
      }
    }
    return uploadedCount;
  }

  Future<void> _uploadCalculationLog(
    Uri endpoint,
    String idempotencyKey,
    String payload,
  ) async {
    final customUploader = calculationLogUploader;
    if (customUploader != null) {
      await customUploader(endpoint, idempotencyKey, payload);
      return;
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint);
      request.headers.contentType = ContentType.json;
      request.headers.set('Idempotency-Key', idempotencyKey);
      request.write(payload);
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Calculation log upload failed with HTTP '
          '${response.statusCode}: $responseBody',
          uri: endpoint,
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Starts queue uploads on network availability changes. Calculations and
  /// their local log writes are not connected to this stream.
  void startConnectivitySync({
    required Uri endpoint,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    if (_connectivitySubscription != null) return;
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        if (!results.contains(ConnectivityResult.none)) {
          unawaited(
            flushPendingLogs(endpoint)
                .catchError((Object error, StackTrace stack) {
                  _reportSyncError(error, stack, onError);
                  return 0;
                }),
          );
        }
      },
      onError: (Object error, StackTrace stack) {
        if (onError != null) {
          onError(error, stack);
        } else {
          developer.log(
            'Connectivity monitoring failed.',
            name: 'vetifi.database',
            error: error,
            stackTrace: stack,
          );
        }
      },
    );
    unawaited(_syncIfConnected(endpoint, onError));
  }

  Future<void> _syncIfConnected(
    Uri endpoint,
    void Function(Object error, StackTrace stackTrace)? onError,
  ) async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (!results.contains(ConnectivityResult.none)) {
        await flushPendingLogs(endpoint);
      }
    } catch (error, stack) {
      _reportSyncError(error, stack, onError);
    }
  }

  void _reportSyncError(
    Object error,
    StackTrace stack,
    void Function(Object error, StackTrace stackTrace)? onError,
  ) {
    if (onError != null) {
      onError(error, stack);
    } else {
      developer.log(
        'Pending calculation log sync failed.',
        name: 'vetifi.database',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> stopConnectivitySync() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  Future<void> close() async {
    await stopConnectivitySync();
    final db = _database;
    _database = null;
    _openingDatabase = null;
    if (db != null && db.isOpen) await db.close();
  }

  Future<String?> _getMetadata(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'app_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value']! as String;
  }

  Future<void> _setMetadata(
    DatabaseExecutor db,
    String key,
    String value,
  ) async {
    await db.insert('app_metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _replaceDrugs(
    Transaction transaction,
    List<Map<String, dynamic>> drugs,
  ) async {
    await transaction.delete('drugs');
    for (final drug in drugs) {
      await _upsertDrug(transaction, drug);
    }
  }

  Future<void> _upsertDrug(
    Transaction transaction,
    Map<String, dynamic> drug,
  ) async {
    final id = drug['id'];
    if (id == null || id.toString().trim().isEmpty) {
      throw const FormatException('Every drug must have a non-empty id.');
    }
    final name = drug['name']?.toString();
    final concentration = drug['concentration']?.toString();
    final route = drug['route']?.toString();
    if (name == null ||
        name.trim().isEmpty ||
        concentration == null ||
        concentration.trim().isEmpty ||
        route == null ||
        route.trim().isEmpty) {
      throw FormatException('Drug $id is missing required fields.');
    }
    await transaction.insert('drugs', {
      'id': id.toString(),
      'name': name,
      'concentration': concentration,
      'route': route,
      'data_json': jsonEncode(drug),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  List<Map<String, dynamic>> _extractDrugs(Map<String, dynamic> payload) {
    final rawDrugs = payload['drugs'];
    if (rawDrugs is! List) {
      throw const FormatException('Dataset payload must contain a drugs list.');
    }
    final drugs = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (final rawDrug in rawDrugs) {
      if (rawDrug is! Map) {
        throw const FormatException('Every drug must be an object.');
      }
      final drug = Map<String, dynamic>.from(rawDrug);
      final id = drug['id']?.toString();
      if (id == null || id.trim().isEmpty || !ids.add(id)) {
        throw const FormatException('Drug ids must be present and unique.');
      }
      drugs.add(drug);
    }
    return drugs;
  }

  String _datasetVersion(Map<String, dynamic> payload) {
    final value = payload['dataset_version'] ?? payload['dataset version'];
    if (value == null || value.toString().trim().isEmpty) {
      throw const FormatException('Dataset version is required.');
    }
    return value.toString();
  }

  int _schemaVersion(Map<String, dynamic> payload) {
    final value = payload['schema_version'] ?? payload['schema version'];
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw const FormatException('A valid schema version is required.');
  }

  Map<String, dynamic> _decodeObject(String source, String label) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw FormatException('$label must be an object.');
    return Map<String, dynamic>.from(decoded);
  }

  String _newIdempotencyKey() {
    final random = Random.secure();
    return 'calc_${DateTime.now().toUtc().microsecondsSinceEpoch}_'
        '${random.nextInt(1 << 32).toRadixString(16)}';
  }
}
