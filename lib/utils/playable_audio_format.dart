const _containerExtensions = <String, String>{
  'mp4': '.m4a',
  'm4a': '.m4a',
  'mov': '.mov',
  '3gp': '.3gp',
  '3g2': '.3g2',
  'ogg': '.ogg',
  'oga': '.ogg',
  'flac': '.flac',
  'mp3': '.mp3',
  'wav': '.wav',
  'w64': '.wav',
  'rf64': '.wav',
  'aiff': '.aiff',
  'aif': '.aiff',
  'caf': '.caf',
  'asf': '.wma',
  'wma': '.wma',
  'ape': '.ape',
  'wv': '.wv',
  'dsf': '.dsf',
  'dff': '.dff',
  'iff': '.dff',
  'matroska': '.mka',
  'mka': '.mka',
  'webm': '.webm',
  'mpegts': '.ts',
  'ts': '.ts',
  'amr': '.amr',
  'aac': '.aac',
  'adts': '.aac',
  'eac3': '.eac3',
  'ec3': '.eac3',
  'ac3': '.ac3',
  'ac4': '.ac4',
  'dts': '.dts',
};

const _codecExtensions = <String, String>{
  'opus': '.opus',
  'eac3': '.eac3',
  'ec3': '.eac3',
  'ac3': '.ac3',
  'ac4': '.ac4',
  'dts': '.dts',
  'amr_nb': '.amr',
  'amr_wb': '.amr',
  'wmav2': '.wma',
  'wmapro': '.wma',
  'wmalossless': '.wma',
  'ape': '.ape',
  'wavpack': '.wv',
  'dsd_lsbf': '.dsf',
  'dsd_msbf': '.dff',
  'dsd_lsbf_planar': '.dsf',
  'dsd_msbf_planar': '.dff',
};

String? playableAudioExtension(String? codec, String? container) {
  final normalizedContainer = container
      ?.trim()
      .toLowerCase()
      .split(',')
      .map((part) => part.trim())
      .firstWhere((part) => part.isNotEmpty, orElse: () => '');
  final normalizedCodec = codec?.trim().toLowerCase() ?? '';
  final byContainer = normalizedContainer == null
      ? null
      : _containerExtensions[normalizedContainer];
  if (normalizedCodec == 'opus' && normalizedContainer == 'ogg') {
    return '.opus';
  }
  if (normalizedContainer == 'wav') return '.wav';
  if (byContainer != null) return byContainer;
  final byCodec = _codecExtensions[normalizedCodec];
  if (byCodec != null) return byCodec;
  final cleaned = normalizedCodec.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (cleaned.isNotEmpty) return '.$cleaned';
  final fallback = (normalizedContainer ?? '').replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return fallback.isEmpty ? null : '.$fallback';
}
