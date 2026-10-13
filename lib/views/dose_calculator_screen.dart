import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/drug_model.dart';
import '../services/database_service.dart';
import '../services/dose_calculator.dart';

class DoseCalculatorScreen extends StatefulWidget {
  const DoseCalculatorScreen({
    super.key,
    required this.drug,
    required this.databaseService,
    required this.doseCalculator,
    this.onCalculationLogged,
  });

  final Drug drug;
  final DatabaseService databaseService;
  final DoseCalculatorService doseCalculator;
  final Future<void> Function()? onCalculationLogged;

  @override
  State<DoseCalculatorScreen> createState() => _DoseCalculatorScreenState();
}

class _DoseCalculatorScreenState extends State<DoseCalculatorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _weightController = TextEditingController();
  late final TextEditingController _doseController;
  late String _species;
  String _weightUnit = 'kg';
  CalculationResult? _result;
  String? _errorMessage;
  String? _logMessage;
  bool _isCalculating = false;

  DoseRange get _doseRange => widget.drug.doses[_species]!;

  @override
  void initState() {
    super.initState();
    _species = widget.drug.doses.keys.first;
    _doseController = TextEditingController(
      text: _formatNumber(_doseRange.min),
    );
  }

  @override
  void dispose() {
    _weightController.dispose();
    _doseController.dispose();
    super.dispose();
  }

  void _selectSpecies(String? species) {
    if (species == null || species == _species) return;
    setState(() {
      _species = species;
      _doseController.text = _formatNumber(_doseRange.min);
      _result = null;
      _errorMessage = null;
      _logMessage = null;
    });
  }

  Future<void> _calculate() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isCalculating = true;
      _result = null;
      _errorMessage = null;
      _logMessage = null;
    });

    final weight = _parseNumber(_weightController.text);
    final dose = _parseNumber(_doseController.text);
    late final CalculationResult result;
    try {
      result = widget.doseCalculator.calculateDose(
        drug: widget.drug,
        species: _species,
        weight: weight,
        weightUnit: _weightUnit,
        dose: dose,
        doseUnit: _doseRange.unit,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Calculation failed: $error';
        _isCalculating = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _result = result;
    });

    try {
      final version = await widget.databaseService.getDatasetVersion();
      if (version == null || version.isEmpty) {
        throw StateError('The local dataset version is unavailable.');
      }
      await widget.databaseService.saveCalculationLog(
        inputs: {
          'drug_id': widget.drug.id,
          'drug_name': widget.drug.name,
          'species': _species,
          'weight': weight,
          'weight_unit': _weightUnit,
          'dose': dose,
          'dose_unit': _doseRange.unit,
        },
        result: {
          'weight_kg': result.weightKg,
          'dose_mg_per_kg': result.doseMgPerKg,
          'total_dose_mg': result.totalDoseMg,
          'volume_ml': result.volumeMl,
          'was_capped': result.wasCapped,
        },
        datasetVersion: version,
      );
      await widget.onCalculationLogged?.call();
      if (!mounted) return;
      setState(() {
        _logMessage = 'Saved to the local calculation outbox.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logMessage =
            'Calculation is shown, but could not be saved to the outbox: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCalculating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doseRange = _doseRange;
    return Scaffold(
      appBar: AppBar(title: Text('Calculate ${widget.drug.name}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.medication_outlined),
              title: Text(widget.drug.name),
              subtitle: Text(
                '${widget.drug.concentration}  ·  ${widget.drug.route}',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('calculator-species'),
                  initialValue: _species,
                  decoration: const InputDecoration(
                    labelText: 'Patient species',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final species in widget.drug.doses.keys)
                      DropdownMenuItem(
                        value: species,
                        child: Text(_capitalize(species)),
                      ),
                  ],
                  onChanged: _selectSpecies,
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('calculator-weight'),
                        controller: _weightController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,]'),
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Patient weight',
                          hintText: 'e.g. 12.5',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => _validatePositiveNumber(
                          value,
                          'Enter a valid weight.',
                        ),
                        onChanged: (_) => _clearResult(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 100,
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('calculator-weight-unit'),
                        initialValue: _weightUnit,
                        decoration: const InputDecoration(
                          labelText: 'Unit',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'kg', child: Text('kg')),
                          DropdownMenuItem(value: 'lb', child: Text('lb')),
                        ],
                        onChanged: (unit) {
                          if (unit == null) return;
                          setState(() {
                            _weightUnit = unit;
                            _result = null;
                            _errorMessage = null;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const ValueKey('calculator-dose'),
                  controller: _doseController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Dose (${doseRange.unit})',
                    helperText:
                        'Allowed range: ${_formatNumber(doseRange.min)}–'
                        '${_formatNumber(doseRange.max)} ${doseRange.unit}',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) => _validateDose(value, doseRange),
                  onChanged: (_) => _clearResult(),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const ValueKey('calculate-dose'),
                  onPressed: _isCalculating ? null : _calculate,
                  icon: _isCalculating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.calculate_outlined),
                  label: Text(
                    _isCalculating ? 'Calculating…' : 'Calculate and save',
                  ),
                ),
              ],
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            _MessageCard(
              message: _errorMessage!,
              color: Theme.of(context).colorScheme.errorContainer,
              icon: Icons.error_outline,
            ),
          ],
          if (_result case final result?) ...[
            const SizedBox(height: 18),
            _CalculationResultCard(
              result: result,
              enteredDose: _parseNumber(_doseController.text),
              doseUnit: doseRange.unit,
              species: _species,
            ),
          ],
          if (_logMessage != null) ...[
            const SizedBox(height: 12),
            _MessageCard(
              message: _logMessage!,
              color: _logMessage!.startsWith('Saved')
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : Theme.of(context).colorScheme.errorContainer,
              icon: _logMessage!.startsWith('Saved')
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
            ),
          ],
        ],
      ),
    );
  }

  void _clearResult() {
    if (_result == null && _errorMessage == null) return;
    setState(() {
      _result = null;
      _errorMessage = null;
      _logMessage = null;
    });
  }

  String? _validateDose(String? value, DoseRange range) {
    final message = _validatePositiveNumber(value, 'Enter a valid dose.');
    if (message != null) return message;
    final dose = _parseNumber(value!);
    if (dose < range.min || dose > range.max) {
      return 'Dose must be within ${_formatNumber(range.min)}–'
          '${_formatNumber(range.max)} ${range.unit}.';
    }
    return null;
  }

  String? _validatePositiveNumber(String? value, String message) {
    if (value == null || value.trim().isEmpty) return message;
    final number = _parseNumber(value);
    if (!number.isFinite || number <= 0) return message;
    return null;
  }

  double _parseNumber(String value) =>
      double.tryParse(value.trim().replaceAll(',', '.')) ?? double.nan;

  String _capitalize(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

  String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
}

class _CalculationResultCard extends StatelessWidget {
  const _CalculationResultCard({
    required this.result,
    required this.enteredDose,
    required this.doseUnit,
    required this.species,
  });

  final CalculationResult result;
  final double enteredDose;
  final String doseUnit;
  final String species;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('calculation-result'),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calculated dose',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _ResultRow(
              label: 'Patient',
              value: '${result.weightKg.toStringAsFixed(2)} kg · '
                  '${species[0].toUpperCase()}${species.substring(1)}',
            ),
            _ResultRow(
              label: 'Dose rate',
              value: '${_format(enteredDose)} $doseUnit',
            ),
            _ResultRow(
              label: 'Total drug',
              value: '${_format(result.totalDoseMg)} mg',
            ),
            _ResultRow(
              label: 'Volume to administer',
              value: '${_format(result.volumeMl)} mL',
              emphasize: true,
            ),
            if (result.wasCapped)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Maximum total dose applied.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _format(double value) => value.toStringAsFixed(3);
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
                fontSize: emphasize ? 18 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.message,
    required this.color,
    required this.icon,
  });

  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: ListTile(
        leading: Icon(icon),
        title: Text(message),
      ),
    );
  }
}
