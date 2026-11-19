import 'package:flutter_test/flutter_test.dart';

/// Equivalente acotado de `pumpAndSettle` para paginas con un indicador que
/// gira sin fin (p. ej. la fila del icono del lanzador fuera de Android):
/// avanza el reloj lo bastante para terminar las animaciones finitas sin
/// esperar a que no queden fotogramas.
Future<void> pumpSettled(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
