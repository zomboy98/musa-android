import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/search_filter_label.dart';

void main() {
  final es = lookupAppLocalizations(const Locale('es', 'ES'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('Spanish app: provider English labels become Spanish by kind', () {
    String label(SearchFilter f) => searchFilterLabel(es, f);
    expect(label(const SearchFilter(id: 'songs', label: 'Songs')), 'Canciones');
    expect(label(const SearchFilter(id: 'albums', label: 'Albums')), 'Álbumes');
    expect(
      label(const SearchFilter(id: 'artists', label: 'Artists')),
      'Artistas',
    );
    expect(
      label(const SearchFilter(id: 'playlists', label: 'Playlists')),
      'Listas de reproducción',
    );
    expect(label(const SearchFilter(id: 'all', label: 'All')), 'Todo');
  });

  test('kind is found by label or icon when the id is opaque', () {
    expect(
      searchFilterLabel(
        es,
        const SearchFilter(id: 'f1', label: 'Albums', icon: 'album'),
      ),
      'Álbumes',
    );
    expect(
      searchFilterLabel(es, const SearchFilter(id: 'f2', icon: 'artist')),
      'Artistas',
    );
  });

  test('unknown kinds and non-Spanish languages keep the declared label', () {
    expect(
      searchFilterLabel(es, const SearchFilter(id: 'video', label: 'Videos')),
      'Videos',
    );
    expect(
      searchFilterLabel(en, const SearchFilter(id: 'songs', label: 'Tracks')),
      'Tracks',
    );
  });

  test('the filter id sent to the extension is not altered', () {
    const filter = SearchFilter(id: 'songs', label: 'Songs');
    searchFilterLabel(es, filter);
    expect(filter.id, 'songs');
  });
}
