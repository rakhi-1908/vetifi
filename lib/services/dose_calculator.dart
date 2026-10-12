import '../models/drug_model.dart';

class CalculationResult {
  const CalculationResult({
    required this.weightKg,
    required this.doseMgPerKg,
    required this.totalDoseMg,
    required this.volumeMl,
    required this.wasCapped,
  });

  final double weightKg;
  final double doseMgPerKg;
  final double totalDoseMg;
  final double volumeMl;
  final bool wasCapped;
}

class CriResult {
  const CriResult({
    required this.weightKg,
    required this.rateMcgPerKgPerMin,
    required this.bagDurationHours,
    required this.drugVolumeMl,
    required this.totalDrugMg,
  });

  final double weightKg;
  final double rateMcgPerKgPerMin;
  final double bagDurationHours;
  final double drugVolumeMl;
  final double totalDrugMg;
}

class DoseCalculatorService {
  const DoseCalculatorService();

  /// Parses a weight and returns kilograms. Pounds are converted before the
  /// supported 0-500 kg range is validated.
  double parseWeight(String input, {String unit = 'kg'}) {
    final value = double.tryParse(input.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) {
      throw const FormatException('Weight must be a positive number.');
    }

    final normalizedUnit = unit.trim().toLowerCase();
    final weightKg = switch (normalizedUnit) {
      'kg' || 'kgs' || 'kilogram' || 'kilograms' => value,
      'lb' || 'lbs' || 'pound' || 'pounds' => value / 2.2046226218,
      _ => throw ArgumentError.value(unit, 'unit', 'Use kg or lb.'),
    };
    if (weightKg <= 0 || weightKg > 500) {
      throw RangeError('Weight must be greater than 0 and at most 500 kg.');
    }
    return weightKg;
  }

  CalculationResult calculateDose({
    required Drug drug,
    required String species,
    required double weight,
    required double dose,
    String weightUnit = 'kg',
    String? doseUnit,
  }) {
    if (drug.isWithdrawn) {
      throw StateError('This drug has been withdrawn and cannot be used.');
    }
    final concentrationMgPerMl = drug.concentrationMgPerMl;
    if (!concentrationMgPerMl.isFinite || concentrationMgPerMl <= 0) {
      throw ArgumentError('Drug concentration must be greater than zero.');
    }
    if (!dose.isFinite || dose <= 0) {
      throw ArgumentError.value(
        dose,
        'dose',
        'Dose must be greater than zero.',
      );
    }

    final normalizedSpecies = species.trim().toLowerCase();
    final doseRange = drug.doses[normalizedSpecies];
    if (doseRange == null) {
      throw ArgumentError('No dose data is available for "$species".');
    }

    final unit = (doseUnit ?? doseRange.unit).trim().toLowerCase();
    final doseMgPerKg = switch (unit) {
      'mg/kg' || 'mg/kg/dose' => dose,
      'mcg/kg' || 'µg/kg' || 'ug/kg' || 'mcg/kg/dose' => dose / 1000,
      _ => throw ArgumentError.value(
        unit,
        'doseUnit',
        'Dose units must be mg/kg or mcg/kg.',
      ),
    };
    final rangeInMgPerKg = _doseRangeInMgPerKg(doseRange);
    if (doseMgPerKg < rangeInMgPerKg.min || doseMgPerKg > rangeInMgPerKg.max) {
      throw RangeError(
        'Dose must be within ${doseRange.min}-${doseRange.max} '
        '${doseRange.unit} for $species.',
      );
    }

    final weightKg = _validatedWeight(weight, weightUnit);
    var totalDoseMg = doseMgPerKg * weightKg;
    var wasCapped = false;
    final maxTotalMg = drug.maxTotalMg;
    if (maxTotalMg != null) {
      if (!maxTotalMg.isFinite || maxTotalMg <= 0) {
        throw ArgumentError('Maximum total dose must be greater than zero.');
      }
      if (totalDoseMg > maxTotalMg) {
        totalDoseMg = maxTotalMg;
        wasCapped = true;
      }
    }

    return CalculationResult(
      weightKg: weightKg,
      doseMgPerKg: doseMgPerKg,
      totalDoseMg: totalDoseMg,
      volumeMl: totalDoseMg / concentrationMgPerMl,
      wasCapped: wasCapped,
    );
  }

  /// Calculates the volume of drug to add to a bag, assuming the bag is
  /// administered at [fluidRateMlPerHour] until empty.
  CriResult calculateCRI({
    required Drug drug,
    required String species,
    required double weight,
    required double rateMcgPerKgPerMin,
    required double bagVolumeMl,
    required double fluidRateMlPerHour,
    String weightUnit = 'kg',
  }) {
    if (drug.isWithdrawn) {
      throw StateError('This drug has been withdrawn and cannot be used.');
    }
    final concentrationMgPerMl = drug.concentrationMgPerMl;
    if (!concentrationMgPerMl.isFinite || concentrationMgPerMl <= 0) {
      throw ArgumentError('Drug concentration must be greater than zero.');
    }
    if (!rateMcgPerKgPerMin.isFinite || rateMcgPerKgPerMin <= 0) {
      throw ArgumentError.value(
        rateMcgPerKgPerMin,
        'rateMcgPerKgPerMin',
        'CRI rate must be greater than zero.',
      );
    }
    if (!bagVolumeMl.isFinite || bagVolumeMl <= 0) {
      throw ArgumentError.value(
        bagVolumeMl,
        'bagVolumeMl',
        'Bag volume must be greater than zero.',
      );
    }
    if (!fluidRateMlPerHour.isFinite || fluidRateMlPerHour <= 0) {
      throw ArgumentError.value(
        fluidRateMlPerHour,
        'fluidRateMlPerHour',
        'Fluid rate must be greater than zero.',
      );
    }

    final normalizedSpecies = species.trim().toLowerCase();
    final matchingRanges = drug.criRanges.where(
      (range) => range.species == null || range.species == normalizedSpecies,
    );
    if (matchingRanges.isEmpty) {
      throw ArgumentError('No CRI data is available for "$species".');
    }
    final range = matchingRanges.first;
    final rateInMcgPerKgPerMin = rateMcgPerKgPerMin;
    final minRate = _criRateInMcgPerKgPerMin(range.min, range.unit);
    final maxRate = _criRateInMcgPerKgPerMin(range.max, range.unit);
    if (rateInMcgPerKgPerMin < minRate || rateInMcgPerKgPerMin > maxRate) {
      throw RangeError(
        'CRI rate must be within ${range.min}-${range.max} ${range.unit}.',
      );
    }

    final weightKg = _validatedWeight(weight, weightUnit);
    final durationHours = bagVolumeMl / fluidRateMlPerHour;
    final totalDrugMg =
        rateInMcgPerKgPerMin * weightKg * durationHours * 60 / 1000;
    final drugVolumeMl = totalDrugMg / concentrationMgPerMl;
    final maxTotalMg = drug.maxTotalMg;
    if (maxTotalMg != null &&
        (!maxTotalMg.isFinite || maxTotalMg <= 0 || totalDrugMg > maxTotalMg)) {
      throw RangeError(
        'CRI dose exceeds the maximum total dose of $maxTotalMg mg.',
      );
    }

    return CriResult(
      weightKg: weightKg,
      rateMcgPerKgPerMin: rateInMcgPerKgPerMin,
      bagDurationHours: durationHours,
      drugVolumeMl: drugVolumeMl,
      totalDrugMg: totalDrugMg,
    );
  }

  double _validatedWeight(double weight, String unit) {
    if (!weight.isFinite || weight <= 0) {
      throw ArgumentError.value(
        weight,
        'weight',
        'Weight must be a positive number.',
      );
    }
    return parseWeight(weight.toString(), unit: unit);
  }

  ({double min, double max}) _doseRangeInMgPerKg(DoseRange range) {
    final unit = range.unit.trim().toLowerCase();
    final factor = switch (unit) {
      'mg/kg' || 'mg/kg/dose' => 1.0,
      'mcg/kg' || 'µg/kg' || 'ug/kg' || 'mcg/kg/dose' => 0.001,
      _ => throw ArgumentError.value(
        range.unit,
        'doseRange.unit',
        'Dose units must be mg/kg or mcg/kg.',
      ),
    };
    return (min: range.min * factor, max: range.max * factor);
  }

  double _criRateInMcgPerKgPerMin(double rate, String unit) {
    final normalizedUnit = unit.trim().toLowerCase();
    return switch (normalizedUnit) {
      'mcg/kg/min' || 'µg/kg/min' || 'ug/kg/min' => rate,
      'mg/kg/min' => rate * 1000,
      _ => throw ArgumentError.value(
        unit,
        'criRange.unit',
        'CRI units must be mcg/kg/min or mg/kg/min.',
      ),
    };
  }
}
