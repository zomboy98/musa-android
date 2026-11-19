import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/provider_icon.dart';

void main() {
  testWidgets('known providers use their own assets and unknowns use fallback', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [
      ProviderIcon(provider: 'Spotify'),
      ProviderIcon(provider: 'apple-music'),
      ProviderIcon(provider: 'ytmusic-spotiflac'),
      ProviderIcon(provider: 'deezer'),
      ProviderIcon(provider: 'tidal-web'),
      ProviderIcon(provider: 'qobuz-web'),
      ProviderIcon(provider: 'soundcloud'),
      ProviderIcon(provider: 'amazon'),
      ProviderIcon(provider: 'beatport'),
      ProviderIcon(provider: 'bugs-music'),
      ProviderIcon(provider: 'genie-music'),
      ProviderIcon(provider: 'jiosaavn'),
      ProviderIcon(provider: 'melon-music'),
      ProviderIcon(provider: 'unrelated-spotify'),
    ]))));
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.map((image) => (image.image as AssetImage).assetName), [
      'assets/images/provider-spotify.png',
      'assets/images/provider-apple-music.png',
      'assets/images/provider-youtube-music.png',
      'assets/images/provider-deezer.png',
      'assets/images/provider-tidal.png',
      'assets/images/provider-qobuz.png',
      'assets/images/provider-soundcloud.png',
      'assets/images/provider-amazon.png',
      'assets/images/provider-beatport.png',
      'assets/images/provider-bugs.png',
      'assets/images/provider-genie.png',
      'assets/images/provider-jiosaavn.png',
      'assets/images/provider-melon.png',
    ]);
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
  });
}
