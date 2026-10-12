import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

import 'database_service.dart';

typedef SyncHttpGet = Future<SyncHttpResponse> Function(Uri uri);

class SyncHttpResponse {
  const SyncHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

enum SyncStatus { offline, current, updated, rejected, failed }

class SyncResult {
  const SyncResult({
    required this.status,
    this.version,
    this.message,
    this.uploadedCalculationLogs = 0,
  });

  final SyncStatus status;
  final String? version;
  final String? message;
  final int uploadedCalculationLogs;
}

class SyncService {
  SyncService({
    required this.databaseService,
    required this.apiBaseUri,
    Connectivity? connectivity,
    SyncHttpGet? httpGet,
    this.isOnline,
    String trustedPublicKeyHex = trustedEd25519PublicKeyHex,
  }) : _connectivity = connectivity ?? Connectivity(),
       _httpGet = httpGet ?? _getWithDio,
       _trustedPublicKey = SyncService._decodeHex(trustedPublicKeyHex);

  static const String trustedEd25519PublicKeyHex =
      'a20f148c600439af5b4607b93cf1464a89c2ae2ba53f9a918bebd4dbbe0f8503';

  static final Ed25519 _ed25519 = Ed25519();
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  final DatabaseService databaseService;
  final Uri apiBaseUri;
  final Connectivity _connectivity;
  final SyncHttpGet _httpGet;
  final Future<bool> Function()? isOnline;
  final List<int> _trustedPublicKey;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Future<SyncResult>? _activeSync;

  Future<SyncResult> synchronize() {
    final active = _activeSync;
    if (active != null) return active;

    final sync = _synchronize();
    _activeSync = sync;
    return sync.whenComplete(() {
      _activeSync = null;
    });
  }

  /// Uploads locally queued calculation logs when connectivity is available.
  /// Calculations themselves only write to SQLite; this method is called by
  /// the background sync path and never by the calculation path.
  Future<int> syncPendingCalculationLogs() async {
    final online = await (isOnline?.call() ?? _checkOnline());
    if (!online) return 0;
    return databaseService.flushPendingLogs(
      apiBaseUri.replace(path: '/v1/calc_logs', query: null, fragment: null),
    );
  }

  Future<SyncResult> _synchronize() async {
    try {
      final online = await (isOnline?.call() ?? _checkOnline());
      if (!online) {
        return const SyncResult(status: SyncStatus.offline);
      }

      final currentVersion = await databaseService.getDatasetVersion();
      final manifestUri = apiBaseUri.replace(
        path: '/v1/manifest',
        queryParameters: {'schema': '2', 'current': ?currentVersion},
      );
      final manifestResponse = await _httpGet(manifestUri);
      if (manifestResponse.statusCode != HttpStatus.ok) {
        return _reject(
          'Manifest request returned HTTP ${manifestResponse.statusCode}.',
        );
      }

      final manifest = _decodeJsonObject(manifestResponse.body, 'manifest');
      if (!await _verifySignedObject(manifest)) {
        return _reject('Manifest signature is invalid or untrusted.');
      }
      if (_readInt(manifest['schema_version'], 'manifest schema_version') !=
          2) {
        return _reject('Manifest uses an unsupported schema version.');
      }
      final targetVersion = _readString(
        manifest['latest_version'],
        'manifest latest_version',
      );
      final manifestHash = _readString(manifest['sha256'], 'manifest sha256');
      if (!_isSha256(manifestHash)) {
        return _reject('Manifest contains an invalid SHA-256 hash.');
      }
      if (targetVersion == currentVersion) {
        return SyncResult(status: SyncStatus.current, version: currentVersion);
      }

      final deltaAvailable = manifest['delta_available'];
      if (deltaAvailable is! bool) {
        return _reject('Manifest delta_available must be a boolean.');
      }
      final datasetUri = _datasetUri(
        targetVersion,
        fromVersion: deltaAvailable ? currentVersion : null,
      );
      final datasetResponse = await _httpGet(datasetUri);
      if (datasetResponse.statusCode != HttpStatus.ok) {
        return _reject(
          'Dataset request returned HTTP ${datasetResponse.statusCode}.',
        );
      }

      final signedDataset = _decodeJsonObject(
        datasetResponse.body,
        'dataset response',
      );
      if (!await _verifySignedObject(signedDataset)) {
        return _reject('Dataset signature is invalid or untrusted.');
      }
      if (_readString(signedDataset['dataset_version'], 'dataset_version') !=
          targetVersion) {
        return _reject('Dataset response version does not match manifest.');
      }

      final signedPayload = signedDataset.containsKey('delta')
          ? signedDataset['delta']
          : signedDataset['payload'];
      if (signedPayload is! Map) {
        return _reject('Dataset response has no valid payload or delta.');
      }
      final expectedHash = _readString(
        signedDataset['sha256'],
        'dataset sha256',
      );
      if (!_isSha256(expectedHash)) {
        return _reject('Dataset response contains an invalid SHA-256 hash.');
      }
      final actualHash = await _hashCanonicalJson(signedPayload);
      if (!_constantTimeEquals(expectedHash.toLowerCase(), actualHash)) {
        return _reject('Dataset payload checksum does not match.');
      }
      if (!signedDataset.containsKey('delta') &&
          !_constantTimeEquals(manifestHash.toLowerCase(), actualHash)) {
        return _reject('Dataset snapshot hash does not match the manifest.');
      }

      await databaseService.applyUpdate(signedDataset);
      return SyncResult(status: SyncStatus.updated, version: targetVersion);
    } on FormatException catch (error) {
      return _reject('Response is malformed or truncated: ${error.message}');
    } on HttpException catch (error) {
      return SyncResult(status: SyncStatus.failed, message: error.message);
    } on SocketException catch (error) {
      return SyncResult(status: SyncStatus.failed, message: error.message);
    } on DioException catch (error) {
      return SyncResult(
        status: SyncStatus.failed,
        message: error.message ?? 'Network request failed.',
      );
    } on StateError catch (error) {
      return _reject(error.message);
    } on ArgumentError catch (error) {
      return _reject(error.message?.toString() ?? 'Invalid update payload.');
    }
  }

  Uri _datasetUri(String version, {String? fromVersion}) => apiBaseUri.replace(
    path: '/v1/datasets/$version',
    queryParameters: {'from': ?fromVersion},
  );

  Future<bool> _verifySignedObject(Map<String, dynamic> value) async {
    final signatureValue = value['signature'];
    final publicKeyValue = value['public_key'];
    if (signatureValue is! String || publicKeyValue is! String) return false;

    final responsePublicKey = _decodeHex(publicKeyValue);
    if (!_constantTimeBytesEquals(responsePublicKey, _trustedPublicKey)) {
      return false;
    }

    final signatureBytes = _decodeBase64(signatureValue);
    if (signatureBytes.length != 64) return false;
    final signedContent = Map<String, dynamic>.from(value)..remove('signature');
    return _ed25519.verify(
      _canonicalJson(signedContent),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          _trustedPublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }

  Future<String> _hashCanonicalJson(Object value) async {
    return crypto.sha256.convert(_canonicalJson(value)).toString();
  }

  List<int> _canonicalJson(Object? value) =>
      utf8.encode(jsonEncode(_canonicalize(value)));

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  Map<String, dynamic> _decodeJsonObject(String body, String label) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw FormatException('$label must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  String _readString(Object? value, String label) {
    if (value is! String || value.isEmpty) {
      throw FormatException('$label must be a non-empty string.');
    }
    return value;
  }

  int _readInt(Object? value, String label) {
    if (value is int) return value;
    throw FormatException('$label must be an integer.');
  }

  bool _isSha256(String value) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static List<int> _decodeHex(String value) {
    if (value.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
      throw FormatException('Ed25519 public key must be 64 hex characters.');
    }
    return [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }

  List<int> _decodeBase64(String value) {
    try {
      return base64Decode(value);
    } on FormatException {
      return const [];
    }
  }

  bool _constantTimeEquals(String first, String second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var i = 0; i < first.length; i++) {
      difference |= first.codeUnitAt(i) ^ second.codeUnitAt(i);
    }
    return difference == 0;
  }

  bool _constantTimeBytesEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var i = 0; i < first.length; i++) {
      difference |= first[i] ^ second[i];
    }
    return difference == 0;
  }

  SyncResult _reject(String message) {
    developer.log(message, name: 'vetifi.sync', level: 900);
    return SyncResult(status: SyncStatus.rejected, message: message);
  }

  void startBackgroundSync({
    void Function(SyncResult result)? onResult,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    if (_connectivitySubscription != null) return;
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        if (!results.contains(ConnectivityResult.none)) {
          unawaited(_runBackgroundSync(onResult, onError));
        }
      },
      onError: (Object error, StackTrace stack) {
        if (onError != null) {
          onError(error, stack);
        } else {
          developer.log(
            'Connectivity monitoring failed.',
            name: 'vetifi.sync',
            error: error,
            stackTrace: stack,
          );
        }
      },
    );
    unawaited(_runBackgroundSync(onResult, onError));
  }

  Future<void> _runBackgroundSync(
    void Function(SyncResult result)? onResult,
    void Function(Object error, StackTrace stackTrace)? onError,
  ) async {
    try {
      final result = await synchronize();
      final uploadedCalculationLogs = await syncPendingCalculationLogs();
      onResult?.call(
        SyncResult(
          status: result.status,
          version: result.version,
          message: result.message,
          uploadedCalculationLogs: uploadedCalculationLogs,
        ),
      );
    } catch (error, stack) {
      if (onError != null) {
        onError(error, stack);
      } else {
        developer.log(
          'Background dataset sync failed unexpectedly.',
          name: 'vetifi.sync',
          error: error,
          stackTrace: stack,
        );
      }
    }
  }

  Future<void> stopBackgroundSync() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  Future<bool> _checkOnline() async {
    final connectivity = await _connectivity.checkConnectivity();
    return !connectivity.contains(ConnectivityResult.none);
  }

  static Future<SyncHttpResponse> _getWithDio(Uri uri) async {
    final response = await _dio.get<String>(uri.toString());
    return SyncHttpResponse(
      statusCode: response.statusCode ?? 0,
      body: response.data ?? '',
    );
  }
}
