import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/queue_tab.dart';

void main() {
  test('quality error names the alternative provider in Spanish', () {
    expect(downloadQualityRequiredMessage(const Locale('es', 'MX'), 'Deezer'),
        'Selecciona una calidad de descarga para Deezer.');
  });
}
