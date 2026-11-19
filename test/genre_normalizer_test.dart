import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/genre_normalizer.dart';

void main() {
  group('normalizeGenres', () {
    test('lo que dice el proveedor se muestra tal cual', () {
      expect(normalizeGenres(['Traditional Mexicano']), [
        'Traditional Mexicano',
      ]);
      expect(normalizeGenres(['Regional']), ['Regional']);
    });

    test('mariachi y ranchera son música tradicional mexicana', () {
      expect(normalizeGenres(['Mariachi']), ['Música tradicional mexicana']);
      expect(normalizeGenres(['Ranchera', 'Mariachi']), [
        'Música tradicional mexicana',
      ]);
    });

    test('divide por punto y coma, barra, coma y barra vertical', () {
      expect(normalizeGenres(['Pop;Rock'], maxGenres: 5), ['Pop', 'Rock']);
      expect(normalizeGenres(['Pop / Rock'], maxGenres: 5), ['Pop', 'Rock']);
      expect(normalizeGenres(['Pop, Rock'], maxGenres: 5), ['Pop', 'Rock']);
      expect(normalizeGenres(['Pop | Rock'], maxGenres: 5), ['Pop', 'Rock']);
    });

    test('quita duplicados tras normalizar', () {
      expect(normalizeGenres(['Rap', 'Hip Hop', 'Hip-Hop/Rap']), [
        'Hip hop / Rap',
      ]);
      expect(normalizeGenres(['Reggaeton', 'Reguetón', 'regueton']), [
        'Reguetón',
      ]);
    });

    test('respeta el máximo y el orden', () {
      expect(normalizeGenres(['Pop', 'Rock', 'Jazz', 'Blues'], maxGenres: 2), [
        'Pop',
        'Rock',
      ]);
      expect(normalizeGenres(['Pop', 'Rock', 'Jazz', 'Blues']), [
        'Pop',
        'Rock',
        'Jazz',
      ]);
      expect(normalizeGenres(['Pop'], maxGenres: 0), isEmpty);
    });

    test('entradas vacías o nulas no dan resultados', () {
      expect(normalizeGenres([null, '', '  ', ';;']), isEmpty);
      expect(normalizeGenres(const []), isEmpty);
    });

    test('cobertura latina', () {
      const expected = {
        'Regional Mexican': 'Regional mexicano',
        'Música Regional Mexicana': 'Regional mexicano',
        'Corridos Tumbados': 'Corridos tumbados',
        'Corridos Bélicos': 'Corridos bélicos',
        'corrido': 'Corridos',
        'Norteño': 'Norteño',
        'Nortena': 'Norteño',
        'Banda': 'Banda',
        'Sierreño': 'Sierreño',
        'Latin Urban': 'Urbano latino',
        'Urbano Latino': 'Urbano latino',
        'Reggaeton': 'Reguetón',
        'Latin Trap': 'Trap latino',
        'Latin Pop': 'Pop latino',
        'Cumbia': 'Cumbia',
        'Salsa': 'Salsa',
        'Bachata': 'Bachata',
        'Merengue': 'Merengue',
        'Ballads': 'Balada',
        'Rock en Español': 'Rock en español',
        'Latin': 'Latino',
        'Vallenato': 'Vallenato',
      };
      expected.forEach((input, output) {
        expect(normalizeGenres([input]), [output], reason: input);
      });
    });

    test('cobertura general en español', () {
      const expected = {
        'Hip Hop': 'Hip hop / Rap',
        'Rap/Hip Hop': 'Hip hop / Rap',
        'Hip-Hop/Rap': 'Hip hop / Rap',
        'Electronic': 'Electrónica',
        'Electronica': 'Electrónica',
        'R&B': 'R&B',
        'RnB': 'R&B',
        'Soul': 'Soul',
        'Jazz': 'Jazz',
        'Classical': 'Clásica',
        'Country': 'Country',
        'Reggae': 'Reggae',
        'K-Pop': 'K-pop',
        'kpop': 'K-pop',
        'Anime': 'Anime',
        'Soundtrack': 'Banda sonora',
        'Alternative': 'Alternativo',
        'Singer/Songwriter': 'Cantautor',
        'Christmas': 'Navideña',
        'Kids': 'Infantil',
        'World': 'Música del mundo',
        'Metal': 'Metal',
        'Punk': 'Punk',
        'Folk': 'Folk',
        'Blues': 'Blues',
        'Gospel': 'Gospel',
      };
      expected.forEach((input, output) {
        expect(normalizeGenres([input]).first, output, reason: input);
      });
    });

    test('R&B/Soul se separa en R&B y Soul', () {
      expect(normalizeGenres(['R&B/Soul']), ['R&B', 'Soul']);
    });

    test('Banda no se confunde con Banda sonora', () {
      expect(normalizeGenres(['Banda']), ['Banda']);
      expect(normalizeGenres(['Banda Sonora']), ['Banda sonora']);
    });

    test('desconocidos conservan su texto con la primera en mayúscula', () {
      expect(normalizeGenres(['phonk drift']), ['Phonk drift']);
      expect(normalizeGenres(['  Gqom ']), ['Gqom']);
    });

    test('reglas por contenido para variantes no listadas', () {
      expect(normalizeGenres(['Nuevos corridos tumbados']), [
        'Corridos tumbados',
      ]);
      expect(normalizeGenres(['Reggaeton Colombiano']), ['Reguetón']);
      expect(normalizeGenres(['Spanish Rock Alternativo']), [
        'Rock en español',
      ]);
    });
  });

  group('formatGenres', () {
    test('une con punto medio y limita a dos por defecto', () {
      expect(formatGenres(['Pop;Rock;Jazz']), 'Pop · Rock');
      expect(
        formatGenres(['Pop;Rock;Jazz'], maxGenres: 3),
        'Pop · Rock · Jazz',
      );
    });

    test('el proveedor manda en la cabecera', () {
      expect(
        formatGenres(['Traditional Mexicano; Rap/Hip Hop']),
        'Traditional Mexicano · Hip hop / Rap',
      );
    });

    test('sin géneros devuelve null', () {
      expect(formatGenres([null, '']), isNull);
    });
  });

  group('genreKey', () {
    test('quita acentos, signos y mayúsculas', () {
      expect(genreKey('  Norteño!! '), 'norteno');
      expect(genreKey('Hip-Hop'), 'hip hop');
      expect(genreKey('R & B'), 'r&b');
    });
  });
}
