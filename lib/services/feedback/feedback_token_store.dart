import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/secure_storage_options.dart';

abstract class FeedbackTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SecureFeedbackTokenStore implements FeedbackTokenStore {
  SecureFeedbackTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: secureStorageAndroidOptions,
            mOptions: secureStorageMacOsOptions,
          );

  static const key = 'feedback_github_token_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      final value = (await _storage.read(key: key))?.trim();
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String token) =>
      _storage.write(key: key, value: token.trim());

  @override
  Future<void> clear() => _storage.delete(key: key);
}

class MemoryFeedbackTokenStore implements FeedbackTokenStore {
  MemoryFeedbackTokenStore([this._token]);

  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token.trim();

  @override
  Future<void> clear() async => _token = null;
}
