class Drug {
  const Drug({
    required this.id,
    required this.name,
    required this.concentration,
    required this.route,
    required this.doses,
    required this.criRanges,
    required this.maxTotalMg,
    required this.isWithdrawn,
  });

  final String id;
  final String name;
  final String concentration;
  final String route;
  final Map<String, DoseRange> doses;
  final List<CriRange> criRanges;
  final double? maxTotalMg;
  final bool isWithdrawn;

  /// Concentration converted to mg/mL. Percentage concentrations are treated
  /// as weight/volume (for example, 10% is 100 mg/mL).
  double get concentrationMgPerMl =>
      parseConcentrationMgPerMl(concentration) ?? 0;

  factory Drug.fromJson(Map<String, dynamic> json) {
    final rawDoses = json['doses'];
    final doses = <String, DoseRange>{};

    if (rawDoses is Map) {
      for (final entry in rawDoses.entries) {
        final species = entry.key.toString().trim().toLowerCase();
        final range = DoseRange.tryParse(entry.value);
        if (species.isNotEmpty && range != null) {
          doses[species] = range;
        }
      }
    } else if (rawDoses is List) {
      for (final entry in rawDoses) {
        if (entry is! Map) continue;
        final species = (entry['species'] ?? '').toString().trim().toLowerCase();
        final range = DoseRange.tryParse(entry);
        if (species.isNotEmpty && range != null) {
          doses[species] = range;
        }
      }
    }

    final rawCriRanges = json['cri_ranges'] ?? json['criRanges'];
    final criRanges = <CriRange>[];
    if (rawCriRanges is List) {
      for (final entry in rawCriRanges) {
        final range = CriRange.tryParse(entry);
        if (range != null) criRanges.add(range);
      }
    } else if (rawCriRanges is Map) {
      for (final entry in rawCriRanges.entries) {
        final range = CriRange.tryParse(entry.value);
        if (range != null) {
          criRanges.add(range.withSpecies(entry.key.toString()));
        }
      }
    }

    return Drug(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      concentration: (json['concentration'] ??
              json['concentration_string'] ??
              '')
          .toString(),
      route: (json['route'] ?? '').toString(),
      doses: Map.unmodifiable(doses),
      criRanges: List.unmodifiable(criRanges),
      maxTotalMg: _asDouble(json['max_total_mg'] ?? json['maxTotalMg']),
      isWithdrawn: _asBool(
        json['is_withdrawn'] ??
            json['withdrawn'] ??
            json['withdrawal_status'] ??
            false,
      ),
    );
  }
}

class DoseRange {
  const DoseRange({
    required this.min,
    required this.max,
    this.unit = 'mg/kg',
  });

  final double min;
  final double max;
  final String unit;

  factory DoseRange.fromJson(Map<String, dynamic> json) {
    final min = _asDouble(
      json['min'] ?? json['minimum'] ?? json['min_dose'] ?? json['dose_min'],
    );
    final max = _asDouble(
      json['max'] ?? json['maximum'] ?? json['max_dose'] ?? json['dose_max'],
    );
    final value = _asDouble(json['dose'] ?? json['value']);
    return DoseRange(
      min: min ?? value ?? 0,
      max: max ?? value ?? min ?? 0,
      unit: (json['unit'] ?? json['dose_unit'] ?? 'mg/kg').toString(),
    );
  }

  static DoseRange? tryParse(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      return DoseRange.fromJson(Map<String, dynamic>.from(value));
    }
    final number = _asDouble(value);
    return number == null
        ? null
        : DoseRange(min: number, max: number);
  }
}

class CriRange {
  const CriRange({
    required this.min,
    required this.max,
    this.unit = 'mcg/kg/min',
    this.species,
  });

  final double min;
  final double max;
  final String unit;
  final String? species;

  CriRange withSpecies(String value) => CriRange(
        min: min,
        max: max,
        unit: unit,
        species: value.trim().toLowerCase(),
      );

  factory CriRange.fromJson(Map<String, dynamic> json) {
    final min = _asDouble(
      json['min'] ?? json['minimum'] ?? json['min_rate'] ?? json['rate_min'],
    );
    final max = _asDouble(
      json['max'] ?? json['maximum'] ?? json['max_rate'] ?? json['rate_max'],
    );
    final value = _asDouble(json['rate'] ?? json['value']);
    return CriRange(
      min: min ?? value ?? 0,
      max: max ?? value ?? min ?? 0,
      unit: (json['unit'] ?? 'mcg/kg/min').toString(),
      species: json['species']?.toString().trim().toLowerCase(),
    );
  }

  static CriRange? tryParse(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      return CriRange.fromJson(Map<String, dynamic>.from(value));
    }
    final number = _asDouble(value);
    return number == null
        ? null
        : CriRange(min: number, max: number);
  }
}

double? parseConcentrationMgPerMl(String concentration) {
  final normalized = concentration.trim().toLowerCase().replaceAll(',', '.');
  final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(.*)$').firstMatch(normalized);
  if (match == null) return null;

  final value = double.tryParse(match.group(1)!);
  if (value == null || !value.isFinite) return null;
  final unit = match.group(2)!.replaceAll(RegExp(r'\s+'), '');

  if (unit == '%') return value * 10;
  if (unit == 'mg/ml' || unit.isEmpty) return value;
  if (unit == 'mcg/ml' || unit == 'µg/ml' || unit == 'ug/ml') {
    return value / 1000;
  }
  if (unit == 'g/ml') return value * 1000;
  return null;
}

double? _asDouble(dynamic value) {
  if (value is num) {
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }
  if (value is String) {
    final result = double.tryParse(value.trim().replaceAll(',', '.'));
    return result != null && result.isFinite ? result : null;
  }
  return null;
}

bool _asBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final normalized = value.toString().trim().toLowerCase();
  return normalized == 'true' ||
      normalized == 'yes' ||
      normalized == 'withdrawn' ||
      normalized == '1';
}
