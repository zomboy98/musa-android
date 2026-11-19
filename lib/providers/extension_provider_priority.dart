// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'extension_provider.dart';

bool _stringListEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String>? _tryDecodeStringListPreference(String rawJson, String key) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException('expected a JSON list');
    }

    final values = <String>[];
    for (final item in decoded) {
      if (item is! String) {
        throw const FormatException('expected string entries');
      }
      final trimmed = item.trim();
      if (trimmed.isNotEmpty) {
        values.add(trimmed);
      }
    }
    return values;
  } catch (e) {
    _log.w('Ignoring invalid $key preference: $e');
    return null;
  }
}

/// Download/metadata/search provider priority: persistence, sanitizing, and
/// reconciliation when extensions are installed, removed, or toggled.
extension ExtensionNotifierProviderPriority on ExtensionNotifier {
  /// Update runtime candidates without rewriting provider choices or preferences.
  /// Read-back also repairs a failed earlier push or a recreated native backend.
  Future<void> synchronizeNativeDownloadPriority() =>
      _queueDownloadPriority(_synchronizeNativeDownloadPriority);

  Future<void> _synchronizeNativeDownloadPriority() async {
    final prefs = await SharedPreferences.getInstance();
    final native = await PlatformBridge.getProviderPriority();
    final raw = prefs.getString(_providerPriorityKey);
    final saved = raw == null
        ? null
        : _tryDecodeStringListPreference(raw, _providerPriorityKey);
    if (_extensionInventoryIncomplete) {
      if (saved != null && !_stringListEquals(native, saved)) {
        await PlatformBridge.setProviderPriority(saved);
      }
      return;
    }
    final preferred =
        saved ??
        (state.providerPriority.isNotEmpty ? state.providerPriority : native);
    final effective = _sanitizeDownloadProviderPriority(preferred);
    if (!_stringListEquals(native, effective)) {
      await PlatformBridge.setProviderPriority(effective);
    }
  }

  Future<void> _reconcileDownloadProviderPriority() =>
      _queueDownloadPriority(_reconcileDownloadProviderPriorityNow);

  Future<void> _reconcileDownloadProviderPriorityNow() async {
    if (_extensionInventoryIncomplete) {
      await _synchronizeNativeDownloadPriority();
      return;
    }
    await _migrateUnifiedSources();
    final recommended = await _recommendedPriority(
      _providerPriorityKey,
      _providerPriorityAutoKey,
      _recommendedDownloadOrder,
    );
    if (recommended != null) {
      if (!_stringListEquals(recommended, state.providerPriority)) {
        await _storeRecommendedPriority(
          _providerPriorityKey,
          _providerPriorityAutoKey,
          recommended,
        );
        await _synchronizeNativeDownloadPriority();
        state = state.copyWith(providerPriority: recommended);
      }
      return;
    }
    if (state.providerPriority.isEmpty) {
      return;
    }

    final sanitized = _sanitizeDownloadProviderPriority(state.providerPriority);
    if (_stringListEquals(sanitized, state.providerPriority)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPriorityKey, jsonEncode(sanitized));
    await _synchronizeNativeDownloadPriority();
    state = state.copyWith(providerPriority: sanitized);
    _log.d('Reconciled provider priority after extension update: $sanitized');
  }

  Future<void> _reconcileMetadataProviderPriority() =>
      _queueMetadataPriority(_reconcileMetadataProviderPriorityNow);

  Future<void> _reconcileMetadataProviderPriorityNow() async {
    if (_extensionInventoryIncomplete) {
      await _loadMetadataProviderPriority();
      return;
    }
    final recommended = await _recommendedPriority(
      _metadataProviderPriorityKey,
      _metadataProviderPriorityAutoKey,
      _recommendedMetadataOrder,
    );
    if (recommended != null) {
      if (!_stringListEquals(recommended, state.metadataProviderPriority)) {
        await _storeRecommendedPriority(
          _metadataProviderPriorityKey,
          _metadataProviderPriorityAutoKey,
          recommended,
        );
        await PlatformBridge.setMetadataProviderPriority(recommended);
        state = state.copyWith(metadataProviderPriority: recommended);
      }
      return;
    }
    if (state.metadataProviderPriority.isEmpty) {
      return;
    }

    final replaced = _replaceRetiredBuiltInMetadataProviders(
      state.metadataProviderPriority,
    );
    final sanitized = _sanitizeMetadataProviderPriority(replaced);
    if (_stringListEquals(sanitized, state.metadataProviderPriority)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_metadataProviderPriorityKey, jsonEncode(sanitized));
    await PlatformBridge.setMetadataProviderPriority(sanitized);
    state = state.copyWith(metadataProviderPriority: sanitized);
    _log.d(
      'Reconciled metadata provider priority after extension update: $sanitized',
    );
  }

  String? _firstEnabledExtensionDownloadProviderId() {
    final enabled = state.extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .toList();
    final order = state.providerPriority.isNotEmpty
        ? state.providerPriority
        : defaultDownloadProviderOrder(enabled);
    for (final id in order) {
      final match = enabled.where((ext) => ext.id == id).firstOrNull;
      if (match != null) return match.id;
    }
    return enabled.map((ext) => ext.id).firstOrNull;
  }

  String? _firstEnabledSearchProviderId() {
    for (final id in state.metadataProviderPriority) {
      final match = state.extensions
          .where((ext) => ext.id == id && ext.enabled && ext.hasCustomSearch)
          .firstOrNull;
      if (match != null) return match.id;
    }
    return defaultSearchExtension(state.extensions)?.id;
  }

  List<String> _recommendedDownloadOrder() => defaultDownloadProviderOrder(
    state.extensions.where((ext) => ext.enabled && ext.hasDownloadProvider),
  );

  List<String> _recommendedMetadataOrder() => defaultMetadataProviderOrder(
    state.extensions.where((ext) => ext.enabled && ext.hasMetadataProvider),
  );

  /// The computed order, only when the user never saved one of their own.
  /// A list saved before this marker existed is treated as the user's.
  Future<List<String>?> _recommendedPriority(
    String key,
    String autoKey,
    List<String> Function() compute,
  ) async {
    if (_extensionInventoryIncomplete) return null;
    final prefs = await SharedPreferences.getInstance();
    final marker = prefs.getBool(autoKey);
    final hasSavedList = prefs.getString(key) != null;
    if (marker == false || (marker == null && hasSavedList)) return null;
    final order = compute();
    return order.isEmpty ? null : order;
  }

  Future<void> _storeRecommendedPriority(
    String key,
    String autoKey,
    List<String> order,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, jsonEncode(order)) ||
        !await prefs.setBool(autoKey, true)) {
      throw StateError('Could not save the recommended provider order');
    }
  }

  /// One-time move from the separate default-service and search-provider
  /// choices to a single ordered list: the old choice becomes the first entry.
  Future<void> _migrateUnifiedSources() async {
    if (_extensionInventoryIncomplete || state.extensions.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_sourcesUnifiedKey) ?? false) return;
    final settings = ref.read(settingsProvider);

    Future<void> hoist(
      String key,
      String autoKey,
      String? wanted,
      bool Function(Extension ext) valid,
      bool applyWithoutList,
      List<String> Function() fallbackOrder,
    ) async {
      final id = wanted?.trim() ?? '';
      if (id.isEmpty) return;
      final ext = state.extensions
          .where(
            (e) =>
                e.enabled && valid(e) && e.id.toLowerCase() == id.toLowerCase(),
          )
          .firstOrNull;
      if (ext == null) return;
      final raw = prefs.getString(key);
      final saved = raw == null
          ? null
          : _tryDecodeStringListPreference(raw, key);
      if (saved == null && (raw != null || !applyWithoutList)) return;
      final base = saved ?? fallbackOrder();
      if (base.isNotEmpty && base.first == ext.id) return;
      final next = [ext.id, ...base.where((e) => e != ext.id)];
      await prefs.setString(key, jsonEncode(next));
      await prefs.setBool(autoKey, false);
    }

    final service = settings.defaultService.trim();
    await hoist(
      _providerPriorityKey,
      _providerPriorityAutoKey,
      replacedBuiltInDownloadProviderFor(service) ?? service,
      (e) => e.hasDownloadProvider,
      settings.playbackProviderConfirmed,
      _recommendedDownloadOrder,
    );
    await hoist(
      _metadataProviderPriorityKey,
      _metadataProviderPriorityAutoKey,
      settings.searchProvider,
      (e) => e.hasMetadataProvider && e.hasCustomSearch,
      false,
      _recommendedMetadataOrder,
    );
    await prefs.setBool(_sourcesUnifiedKey, true);
  }

  /// Whether each list is still the one the app computed, not one the user set.
  Future<({bool audio, bool metadata})> recommendedOrderFlags() async {
    final prefs = await SharedPreferences.getInstance();
    bool flag(String key, String autoKey) {
      final marker = prefs.getBool(autoKey);
      return marker ?? prefs.getString(key) == null;
    }

    return (
      audio: flag(_providerPriorityKey, _providerPriorityAutoKey),
      metadata: flag(
        _metadataProviderPriorityKey,
        _metadataProviderPriorityAutoKey,
      ),
    );
  }

  /// Back to the order the app computes from what each add-on declares.
  Future<void> resetProviderPriorityToRecommended() =>
      _queueDownloadPriority(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_providerPriorityKey);
        await prefs.remove(_providerPriorityAutoKey);
        await _loadProviderPriority(confirmDefault: true);
      });

  Future<void> resetMetadataProviderPriorityToRecommended() =>
      _queueMetadataPriority(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_metadataProviderPriorityKey);
        await prefs.remove(_metadataProviderPriorityAutoKey);
        await _loadMetadataProviderPriority();
      });

  String? _replacedBuiltInProviderFor(
    String providerId,
    bool Function(Extension ext) hasCapability,
  ) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    return state.extensions
        .where(
          (ext) =>
              ext.enabled &&
              hasCapability(ext) &&
              ext.replacesBuiltInProviders.contains(normalized),
        )
        .map((ext) => ext.id)
        .firstOrNull;
  }

  String? replacedBuiltInDownloadProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasDownloadProvider);

  String? replacedBuiltInSearchProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasCustomSearch);

  String? replacedBuiltInMetadataProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasMetadataProvider);

  bool downloadProviderReplacesLegacyProvider(
    String providerId,
    String legacyProviderId,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedLegacy = legacyProviderId.trim().toLowerCase();
    if (normalizedProvider.isEmpty || normalizedLegacy.isEmpty) return false;
    if (normalizedProvider == normalizedLegacy) return true;

    final extension = state.extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .where((ext) => ext.id.toLowerCase() == normalizedProvider)
        .firstOrNull;
    return extension?.replacesBuiltInProviders.contains(normalizedLegacy) ??
        false;
  }

  Future<void> _reconcileDefaultDownloadService({
    String? removedId,
    bool confirmed = false,
  }) async {
    final settings = ref.read(settingsProvider);
    final preferredExtensionId = _firstEnabledExtensionDownloadProviderId();
    final currentService = settings.defaultService.trim();

    if (currentService.isEmpty) {
      if (preferredExtensionId != null) {
        _setDownloadProvider(preferredExtensionId, confirmed: confirmed);
        _log.d(
          'Adopted first enabled download extension as default service: $preferredExtensionId',
        );
      }
      return;
    }

    final currentExtension = state.extensions
        .where((ext) => ext.id == currentService)
        .firstOrNull;
    // A partial scan cannot tell a temporarily missing provider from one
    // that was removed. Runtime fallback still uses the available providers.
    if (_extensionInventoryIncomplete &&
        currentExtension == null &&
        currentService != removedId) {
      return;
    }

    final isMissingOrInvalidExtension =
        currentExtension == null ||
        !currentExtension.enabled ||
        !currentExtension.hasDownloadProvider;
    if (preferredExtensionId == null) {
      if (isMissingOrInvalidExtension) {
        _setDownloadProvider('');
        _log.d(
          'Cleared default service because $currentService is no longer available',
        );
      }
      return;
    }
    if (preferredExtensionId.toLowerCase() != currentService.toLowerCase()) {
      _setDownloadProvider(preferredExtensionId, confirmed: confirmed);
      _log.d(
        'Default service follows the first audio provider: $preferredExtensionId',
      );
    }
  }

  void reconcileSearchProvider() => _reconcileSearchProvider();

  void _reconcileSearchProvider({String? removedId}) {
    final settings = ref.read(settingsProvider);
    final currentSearchProvider = settings.searchProvider?.trim() ?? '';

    if (settings.searchProviderPinned && currentSearchProvider.isNotEmpty) {
      final pinnedStillServes = state.extensions.any(
        (ext) =>
            ext.enabled &&
            ext.hasCustomSearch &&
            ext.id == currentSearchProvider,
      );
      if (pinnedStillServes ||
          (currentSearchProvider != removedId &&
              isProviderMissingFromPartialInventory(currentSearchProvider))) {
        return;
      }
    }
    final preferredSearchProvider = _firstEnabledSearchProviderId() ?? '';

    if (currentSearchProvider.isEmpty) {
      if (preferredSearchProvider.isNotEmpty) {
        ref
            .read(settingsProvider.notifier)
            .setSearchProviderExtension(preferredSearchProvider);
        _log.d(
          'Adopted first enabled search provider as default: $preferredSearchProvider',
        );
      }
      return;
    }

    if (currentSearchProvider != removedId &&
        isProviderMissingFromPartialInventory(currentSearchProvider)) {
      return;
    }

    final replacementExtensionId = replacedBuiltInSearchProviderFor(
      currentSearchProvider,
    );
    if (replacementExtensionId != null) {
      ref
          .read(settingsProvider.notifier)
          .setSearchProviderExtension(replacementExtensionId);
      _log.d(
        'Migrated retired built-in search provider $currentSearchProvider to $replacementExtensionId',
      );
      return;
    }

    final hasMatchingExtension = state.extensions.any(
      (ext) =>
          ext.enabled && ext.hasCustomSearch && ext.id == currentSearchProvider,
    );
    if (hasMatchingExtension) {
      if (preferredSearchProvider.isNotEmpty &&
          preferredSearchProvider != currentSearchProvider) {
        ref
            .read(settingsProvider.notifier)
            .setSearchProviderExtension(preferredSearchProvider);
        _log.d(
          'Search provider follows the first information provider: $preferredSearchProvider',
        );
      }
    } else {
      ref
          .read(settingsProvider.notifier)
          .setSearchProviderExtension(
            preferredSearchProvider.isNotEmpty ? preferredSearchProvider : null,
          );
      _log.d(
        preferredSearchProvider.isNotEmpty
            ? 'Reset stale search provider $currentSearchProvider to $preferredSearchProvider'
            : 'Cleared stale search provider because $currentSearchProvider is no longer available',
      );
    }
  }

  Future<Map<String, dynamic>> getExtensionSettings(String extensionId) async {
    try {
      return await PlatformBridge.getExtensionSettings(extensionId);
    } catch (e) {
      _log.e('Failed to get extension settings: $e');
      return {};
    }
  }

  Future<bool> setExtensionSettings(
    String extensionId,
    Map<String, dynamic> settings,
  ) async {
    try {
      await PlatformBridge.setExtensionSettings(extensionId, settings);
      ref.invalidate(extensionSettingsProvider(extensionId));
      state = state.copyWith(
        settingsRevisions: {
          ...state.settingsRevisions,
          extensionId: (state.settingsRevisions[extensionId] ?? 0) + 1,
        },
      );
      _log.d('Updated settings for extension: $extensionId');
      return true;
    } catch (e) {
      _log.e('Failed to set extension settings: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> setHomeFeedRegion(String extensionId, String region) async {
    final extension = state.extensions
        .where((extension) => extension.id == extensionId)
        .firstOrNull;
    final setting = extension?.homeFeedRegionSetting;
    if (setting == null || !setting.options!.contains(region)) return false;
    try {
      final settings = await PlatformBridge.getExtensionSettings(extensionId);
      if ((settings[setting.key] ?? setting.defaultValue) == region) {
        return true;
      }
      return await setExtensionSettings(extensionId, {
        ...settings,
        setting.key: region,
      });
    } catch (error) {
      _log.e('Failed to update home feed country: $error');
      state = state.copyWith(error: error.toString());
      return false;
    }
  }

  /// Shared load path for the download/metadata priority lists: prefs first
  /// (sanitized), falling back to backend defaults, then persist + push the
  /// result back to the backend.
  Future<List<String>> _loadPriorityList({
    required String prefsKey,
    required String label,
    required List<String> Function(List<String>) sanitizeStored,
    required List<String> Function(List<String>) sanitizeBackend,
    required Future<List<String>> Function() fetchBackend,
    required Future<void> Function(List<String>) pushBackend,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(prefsKey);
    final saved = savedJson == null
        ? null
        : _tryDecodeStringListPreference(savedJson, prefsKey);
    final source = saved ?? await fetchBackend();
    if (_extensionInventoryIncomplete) {
      // Native order may be the only authoritative copy of missing IDs. A
      // saved order can be applied whole, and the runtime filters candidates.
      if (saved != null) await pushBackend(saved);
      return source;
    }

    final priority = saved == null
        ? sanitizeBackend(source)
        : sanitizeStored(source);
    _log.d('Loaded $label: $priority');
    await prefs.setString(prefsKey, jsonEncode(priority));
    await pushBackend(priority);
    return priority;
  }

  Future<void> loadProviderPriority() =>
      _queueDownloadPriority(_loadProviderPriority);

  Future<void> _migrateAlphabeticalDownloadPriority() async {
    if (_extensionInventoryIncomplete) return;
    final installed = state.extensions
        .where((ext) => ext.hasDownloadProvider)
        .toList();
    if (installed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_providerPriorityQualityOrderKey) ?? false) return;
    final raw = prefs.getString(_providerPriorityKey);
    final saved = raw == null
        ? null
        : _tryDecodeStringListPreference(raw, _providerPriorityKey);
    if (raw != null && saved == null) return;
    if (saved != null && isAlphabeticalDownloadOrder(saved, installed)) {
      final enabled = installed.where((ext) => ext.enabled);
      final upgraded = defaultDownloadProviderOrder(enabled);
      if (!await prefs.setString(_providerPriorityKey, jsonEncode(upgraded))) {
        return;
      }
      await prefs.setBool(_providerPriorityAutoKey, true);
      _log.d('Moved untouched alphabetical download priority to $upgraded');
    }
    await prefs.setBool(_providerPriorityQualityOrderKey, true);
  }

  Future<void> _loadProviderPriority({bool confirmDefault = false}) async {
    try {
      await _migrateAlphabeticalDownloadPriority();
      await _migrateUnifiedSources();
      final recommended = await _recommendedPriority(
        _providerPriorityKey,
        _providerPriorityAutoKey,
        _recommendedDownloadOrder,
      );
      if (recommended != null) {
        await _storeRecommendedPriority(
          _providerPriorityKey,
          _providerPriorityAutoKey,
          recommended,
        );
        await _synchronizeNativeDownloadPriority();
        state = state.copyWith(providerPriority: recommended);
        await _reconcileDefaultDownloadService(confirmed: confirmDefault);
        return;
      }
      final priority = await _loadPriorityList(
        prefsKey: _providerPriorityKey,
        label: 'provider priority',
        sanitizeStored: _sanitizeDownloadProviderPriority,
        sanitizeBackend: _sanitizeDownloadProviderPriority,
        fetchBackend: PlatformBridge.getProviderPriority,
        pushBackend: (_) => _synchronizeNativeDownloadPriority(),
      );
      state = state.copyWith(providerPriority: priority);
      await _reconcileDefaultDownloadService(confirmed: confirmDefault);
    } catch (e) {
      _log.e('Failed to load provider priority: $e');
    }
  }

  Future<bool> setProviderPriority(List<String> priority) {
    final snapshot = List<String>.of(priority);
    return _queueDownloadPriority(() => _saveProviderPriority(snapshot));
  }

  Future<T> _queueDownloadPriority<T>(Future<T> Function() operation) {
    final result = _downloadPrioritySave.then((_) => operation());
    _downloadPrioritySave = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _saveProviderPriority(List<String> priority) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sanitized = _sanitizeDownloadProviderPriority(priority);
      final partial = _extensionInventoryIncomplete;
      final saved = partial
          ? await _mergePartialPriority(
              prefs,
              _providerPriorityKey,
              sanitized,
              PlatformBridge.getProviderPriority,
            )
          : sanitized;
      await _persistAndApplyPriority(prefs, _providerPriorityKey, saved, () {
        return partial
            ? PlatformBridge.setProviderPriority(saved)
            : _synchronizeNativeDownloadPriority();
      });
      await prefs.setBool(_providerPriorityAutoKey, false);
      state = state.copyWith(providerPriority: saved);
      await _reconcileDefaultDownloadService(confirmed: true);
      _log.d('Saved provider priority: $saved');
      return true;
    } catch (e) {
      _log.e('Failed to set provider priority: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<List<String>> _mergePartialPriority(
    SharedPreferences prefs,
    String key,
    List<String> visibleOrder,
    Future<List<String>> Function() readNative,
  ) async {
    final raw = prefs.getString(key);
    final saved = raw == null ? null : _tryDecodeStringListPreference(raw, key);
    final original = saved ?? await readNative();
    final visible = visibleOrder.toSet();
    var next = 0;
    return [
      for (final id in original)
        if (!visible.contains(id))
          id
        else if (next < visibleOrder.length)
          visibleOrder[next++],
      ...visibleOrder.skip(next),
    ];
  }

  Future<void> _persistAndApplyPriority(
    SharedPreferences prefs,
    String key,
    List<String> priority,
    Future<void> Function() apply,
  ) async {
    final previous = prefs.getString(key);
    final written = jsonEncode(priority);
    try {
      if (!await prefs.setString(key, written)) {
        throw StateError('Could not save provider priority');
      }
      await apply();
    } catch (_) {
      if (prefs.getString(key) != written) rethrow;
      final restored = previous == null
          ? await prefs.remove(key)
          : await prefs.setString(key, previous);
      if (!restored) {
        throw StateError('Could not restore the previous provider priority');
      }
      rethrow;
    }
  }

  List<String> _sanitizeDownloadProviderPriority(List<String> input) {
    final allowed = getAllDownloadProviders().toSet();
    final preferredOrder = defaultDownloadProviderOrder(
      state.extensions.where((ext) => ext.enabled && ext.hasDownloadProvider),
    );
    final result = <String>[];

    for (final provider in input) {
      if (allowed.contains(provider) && !result.contains(provider)) {
        result.add(provider);
      }
    }

    for (final provider in preferredOrder) {
      if (!result.contains(provider)) {
        result.add(provider);
      }
    }

    return result;
  }

  Future<void> loadMetadataProviderPriority() =>
      _queueMetadataPriority(_loadMetadataProviderPriority);

  Future<void> _loadMetadataProviderPriority() async {
    try {
      await _migrateUnifiedSources();
      final recommended = await _recommendedPriority(
        _metadataProviderPriorityKey,
        _metadataProviderPriorityAutoKey,
        _recommendedMetadataOrder,
      );
      if (recommended != null) {
        await _storeRecommendedPriority(
          _metadataProviderPriorityKey,
          _metadataProviderPriorityAutoKey,
          recommended,
        );
        await PlatformBridge.setMetadataProviderPriority(recommended);
        state = state.copyWith(metadataProviderPriority: recommended);
        _reconcileSearchProvider();
        return;
      }
      final priority = await _loadPriorityList(
        prefsKey: _metadataProviderPriorityKey,
        label: 'metadata provider priority',
        sanitizeStored: (saved) => _sanitizeMetadataProviderPriority(
          _replaceRetiredBuiltInMetadataProviders(saved),
        ),
        sanitizeBackend: _sanitizeMetadataProviderPriority,
        fetchBackend: PlatformBridge.getMetadataProviderPriority,
        pushBackend: PlatformBridge.setMetadataProviderPriority,
      );
      state = state.copyWith(metadataProviderPriority: priority);
      _reconcileSearchProvider();
    } catch (e) {
      _log.e('Failed to load metadata provider priority: $e');
    }
  }

  Future<bool> setMetadataProviderPriority(List<String> priority) {
    final snapshot = List<String>.of(priority);
    return _queueMetadataPriority(
      () => _saveMetadataProviderPriority(snapshot),
    );
  }

  Future<T> _queueMetadataPriority<T>(Future<T> Function() operation) {
    final result = _metadataPrioritySave.then((_) => operation());
    _metadataPrioritySave = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _saveMetadataProviderPriority(List<String> priority) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sanitized = _sanitizeMetadataProviderPriority(
        _replaceRetiredBuiltInMetadataProviders(priority),
      );
      final saved = _extensionInventoryIncomplete
          ? await _mergePartialPriority(
              prefs,
              _metadataProviderPriorityKey,
              sanitized,
              PlatformBridge.getMetadataProviderPriority,
            )
          : sanitized;
      await _persistAndApplyPriority(
        prefs,
        _metadataProviderPriorityKey,
        saved,
        () => PlatformBridge.setMetadataProviderPriority(saved),
      );
      await prefs.setBool(_metadataProviderPriorityAutoKey, false);
      state = state.copyWith(metadataProviderPriority: saved);
      _reconcileSearchProvider();
      _log.d('Saved metadata provider priority: $saved');
      return true;
    } catch (e) {
      _log.e('Failed to set metadata provider priority: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Priority lists for the extensions section of a backup. Empty lists are
  /// omitted so restoring them never replaces a device's own order.
  Map<String, dynamic> providerPriorityBackup() => {
    if (state.providerPriority.isNotEmpty)
      _providerPriorityKey: List<String>.from(state.providerPriority),
    if (state.metadataProviderPriority.isNotEmpty)
      _metadataProviderPriorityKey: List<String>.from(
        state.metadataProviderPriority,
      ),
  };

  /// Applies backed-up priority lists. Call after restored extensions are
  /// installed: the setters drop IDs that are not available yet, and later
  /// installs would otherwise be appended after the defaults.
  Future<void> restoreProviderPriorityBackup(Map<String, dynamic> data) async {
    final download = _backupProviderIds(data[_providerPriorityKey]);
    if (download.isNotEmpty) await setProviderPriority(download);
    final metadata = _backupProviderIds(data[_metadataProviderPriorityKey]);
    if (metadata.isNotEmpty) await setMetadataProviderPriority(metadata);
  }

  List<String> _backupProviderIds(Object? raw) => raw is List
      ? _distinctProviderIds(raw.whereType<String>())
      : const <String>[];

  List<String> getAllDownloadProviders() {
    return _distinctProviderIds(
      state.extensions
          .where((ext) => ext.enabled && ext.hasDownloadProvider)
          .map((ext) => ext.id),
    );
  }

  List<String> getAllMetadataProviders() =>
      _distinctProviderIds(_recommendedMetadataOrder());

  List<String> _distinctProviderIds(Iterable<String> ids) {
    final seen = <String>{};
    final result = <String>[];
    for (final id in ids) {
      final normalized = id.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        result.add(normalized);
      }
    }
    return result;
  }

  List<String> _replaceRetiredBuiltInMetadataProviders(List<String> input) {
    final result = <String>[];
    for (final provider in input) {
      final replacement = replacedBuiltInMetadataProviderFor(provider);
      final resolved = replacement ?? provider;
      if (!result.contains(resolved)) {
        result.add(resolved);
      }
    }
    return result;
  }

  List<String> _sanitizeMetadataProviderPriority(List<String> input) {
    final preferredOrder = getAllMetadataProviders();
    final allowed = preferredOrder.toSet();
    final result = <String>[];

    for (final provider in input) {
      if (allowed.contains(provider) && !result.contains(provider)) {
        result.add(provider);
      }
    }

    if (result.isEmpty && preferredOrder.isNotEmpty) {
      return List<String>.from(preferredOrder);
    }

    for (final provider in preferredOrder) {
      if (!result.contains(provider)) {
        result.add(provider);
      }
    }

    return result;
  }
}
