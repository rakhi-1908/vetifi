import 'package:flutter_test/flutter_test.dart';
import 'package:vetifi/models/drug_model.dart';
import 'package:vetifi/services/dose_calculator.dart';

void main() {
  const calculator = DoseCalculatorService();

  Drug drugFrom(Map<String, dynamic> values) => Drug.fromJson(values);

  test('parses comma decimal weights and converts pounds to kilograms', () {
    expect(calculator.parseWeight('4,5'), 4.5);
    expect(
      calculator.parseWeight('22.046226218', unit: 'lb'),
      closeTo(10, 1e-8),
    );
    expect(() => calculator.parseWeight('501'), throwsRangeError);
    expect(() => calculator.parseWeight('0'), throwsFormatException);
  });

  test('parses percentage concentrations and species dose ranges', () {
    final drug = drugFrom({
      'id': 12,
      'name': 'Test drug',
      'concentration': '10%',
      'route': 'IV',
      'doses': {
        'Dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'},
        'cat': null,
      },
    });

    expect(drug.id, '12');
    expect(drug.concentrationMgPerMl, 100);
    expect(drug.doses.keys, ['dog']);
  });

  test('calculates dose, converts mcg, and caps total dose', () {
    final drug = drugFrom({
      'id': 'test',
      'name': 'Test',
      'concentration': '20 mg/mL',
      'doses': {
        'dog': {'min': 1000, 'max': 3000, 'unit': 'mcg/kg'},
      },
      'max_total_mg': 20,
    });

    final result = calculator.calculateDose(
      drug: drug,
      species: 'DOG',
      weight: 10,
      dose: 3000,
    );

    expect(result.doseMgPerKg, 3);
    expect(result.totalDoseMg, 20);
    expect(result.volumeMl, 1);
    expect(result.wasCapped, isTrue);
  });

  test(
    'rejects withdrawn drugs, missing species, and invalid concentrations',
    () {
      final withdrawnDrug = drugFrom({
        'name': 'Withdrawn',
        'concentration': '1 mg/mL',
        'withdrawn': true,
        'doses': {'dog': 1},
      });
      expect(
        () => calculator.calculateDose(
          drug: withdrawnDrug,
          species: 'dog',
          weight: 5,
          dose: 1,
        ),
        throwsStateError,
      );

      final noSpeciesData = drugFrom({
        'name': 'No data',
        'concentration': '1 mg/mL',
        'doses': {'cat': 1},
      });
      expect(
        () => calculator.calculateDose(
          drug: noSpeciesData,
          species: 'dog',
          weight: 5,
          dose: 1,
        ),
        throwsArgumentError,
      );

      final invalidConcentration = drugFrom({
        'name': 'Invalid',
        'concentration': '0 mg/mL',
        'doses': {'dog': 1},
      });
      expect(
        () => calculator.calculateDose(
          drug: invalidConcentration,
          species: 'dog',
          weight: 5,
          dose: 1,
        ),
        throwsArgumentError,
      );
    },
  );

  test('calculates CRI bag additive volume and duration', () {
    final drug = drugFrom({
      'name': 'CRI drug',
      'concentration': '10 mg/mL',
      'cri_ranges': [
        {'min': 1, 'max': 10, 'unit': 'mcg/kg/min', 'species': 'dog'},
      ],
    });

    final result = calculator.calculateCRI(
      drug: drug,
      species: 'dog',
      weight: 10,
      rateMcgPerKgPerMin: 5,
      bagVolumeMl: 500,
      fluidRateMlPerHour: 50,
    );

    expect(result.bagDurationHours, 10);
    expect(result.totalDrugMg, 30);
    expect(result.drugVolumeMl, 3);
  });
}
