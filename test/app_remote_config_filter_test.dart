import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/app_remote_config_service.dart';

void main() {
  group('AppRemoteConfig', () {
    test('parses announcement payloads from API JSON', () {
      final config = AppRemoteConfig.fromJson({
        'announcement': {
          'id': 'hello-2026',
          'enabled': true,
          'title': 'Server message',
          'message': 'A clear message for users',
          'cta_enabled': true,
          'cta_label': 'Read more',
          'cta_url': 'https://example.test/info',
          'starts_at': '2026-05-01T00:00:00Z',
          'ends_at': '2026-06-01T00:00:00Z',
          'min_version': '4.5.0',
          'priority': 'high',
        },
      });

      expect(config.announcement?.id, 'hello-2026');
      expect(config.announcement?.hasCta, isTrue);
      expect(
        config.announcement?.isActive(
          now: DateTime.utc(2026, 5, 11),
          currentVersion: '4.5.1',
        ),
        isTrue,
      );
    });

    test('requires enabled announcement CTA with label and url', () {
      final disabledCta = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'No button',
        'cta_label': 'Open',
        'cta_url': 'https://api.zarz.moe',
      });
      final missingLabel = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'No button',
        'cta_enabled': true,
        'cta_url': 'https://example.test',
      });
      final enabledCta = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'With button',
        'cta_enabled': true,
        'cta_label': 'Read More',
        'cta_url': 'https://example.test',
      });

      expect(disabledCta.hasCta, isFalse);
      expect(missingLabel.hasCta, isFalse);
      expect(enabledCta.hasCta, isTrue);
      expect(enabledCta.ctaLabel, 'Read More');
    });

    test('filters inactive announcements by window and app version', () {
      final announcement = RemoteAnnouncement.fromJson({
        'id': 'future',
        'title': 'Future',
        'message': 'Not yet',
        'starts_at': '2026-06-01T00:00:00Z',
        'min_version': '4.6.0',
      });

      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 5, 11),
          currentVersion: '4.5.1',
        ),
        isFalse,
      );
      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 6, 2),
          currentVersion: '4.5.1',
        ),
        isFalse,
      );
      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 6, 2),
          currentVersion: '4.6.0',
        ),
        isTrue,
      );
    });
  });
}
