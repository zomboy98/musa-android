import 'dart:io';
import 'dart:typed_data';

class Ac4StructureCheck {
  static const minimumBytes = 1024;
  static const _maxMoovBytes = 32 * 1024 * 1024;

  static Future<bool> isValid(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final length = await handle.length();
      if (length < minimumBytes) return false;
      var offset = 0;
      var hasFtyp = false;
      var moovOk = false;
      var hasMedia = false;
      while (offset < length) {
        if (length - offset < 8) return false;
        await handle.setPosition(offset);
        final header = await handle.read(16);
        if (header.length < 8) return false;
        final data = ByteData.sublistView(Uint8List.fromList(header));
        var size = data.getUint32(0);
        final type = String.fromCharCodes(header.sublist(4, 8));
        if (size == 1) {
          if (header.length < 16) return false;
          size = data.getUint64(8);
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < 8 || offset + size > length) return false;
        switch (type) {
          case 'ftyp':
            hasFtyp = offset == 0;
          case 'moov':
            if (size > _maxMoovBytes) return false;
            await handle.setPosition(offset);
            final body = Uint8List.fromList(await handle.read(size));
            if (body.length != size) return false;
            if (!_inspectMoov(body)) return false;
            moovOk = true;
          case 'mdat':
            if (size > 8) hasMedia = true;
          case 'moof':
            hasMedia = true;
        }
        offset += size;
      }
      return hasFtyp && moovOk && hasMedia;
    } catch (_) {
      return false;
    } finally {
      await handle?.close();
    }
  }

  static bool _inspectMoov(Uint8List moov) {
    final text = String.fromCharCodes(moov);
    if (!text.contains('dac4')) return false;
    final mvhd = text.indexOf('mvhd');
    if (mvhd < 0 || mvhd + 4 + 32 > moov.length) return false;
    final data = ByteData.sublistView(moov);
    final version = moov[mvhd + 4];
    final int timescale;
    final int duration;
    if (version == 1) {
      if (mvhd + 4 + 32 > moov.length) return false;
      timescale = data.getUint32(mvhd + 4 + 20);
      duration = data.getUint64(mvhd + 4 + 24);
    } else {
      timescale = data.getUint32(mvhd + 4 + 12);
      duration = data.getUint32(mvhd + 4 + 16);
    }
    if (timescale <= 0) return false;
    final fragmented = text.contains('mvex');
    if (duration <= 0 && !fragmented) return false;
    return true;
  }
}
