import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_artist_images_provider.dart';
import 'package:mornye/services/setup_artist_catalog.dart';

void main() {
  test('ranks summed case variants without merging punctuation', () {
    expect(
      rankLibraryArtists({
        'Other': 90,
        ' Artist ': 50,
        'artist': 50,
        'Artist!': 80,
        '': 1000,
      }),
      ['Artist', 'Other', 'Artist!'],
    );
  });

  test(
    'only unique exact matches have images and requests are bounded',
    () async {
      final calls = <String>[];
      final images = await resolveLibraryArtistImages(
        ['One', 'Two', 'Three', 'Four', 'Five'],
        (name) async {
          calls.add(name);
          if (name == 'Two') {
            return [
              const SetupArtistChoice('Two', imageUrl: 'a'),
              const SetupArtistChoice('two', imageUrl: 'b'),
            ];
          }
          if (name == 'Three') throw StateError('offline');
          if (name == 'Four') {
            return [const SetupArtistChoice('Four other', imageUrl: 'c')];
          }
          return [const SetupArtistChoice('one', imageUrl: 'image')];
        },
      );
      expect(calls, ['One', 'Two', 'Three', 'Four']);
      expect(images, {'one': 'image'});
    },
  );

  test('deduplicates and discards results after disposal', () async {
    var cancelled = false;
    final calls = <String>[];
    final images = await resolveLibraryArtistImages(['One', 'one', 'Two'], (
      name,
    ) async {
      calls.add(name);
      if (name == 'Two') cancelled = true;
      return [SetupArtistChoice(name, imageUrl: name)];
    }, isCancelled: () => cancelled);
    expect(calls, ['One', 'Two']);
    expect(images, {'one': 'One'});
  });
}
