"""Rebuild the bundled SoundCloud package from its checked-in source."""
import hashlib
import json
import zipfile
from pathlib import Path

root = Path(__file__).parents[1]
source = root / 'extensions_source/soundcloud'
package = root / 'assets/bundled_extensions/soundcloud.sflx'
names = ['manifest.json', 'index.js', 'LICENSE', 'COPYING', 'NOTICE']
with zipfile.ZipFile(package, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for name in names:
        info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, (source / name).read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
manifest = root / 'assets/bundled_extensions/manifest.json'
data = json.loads(manifest.read_text(encoding='utf-8'))
entry = next(e for e in data['extensions'] if e['id'] == 'soundcloud')
entry['version'] = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))['version']
entry['sha256'] = hashlib.sha256(package.read_bytes()).hexdigest()
manifest.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')
print('SoundCloud bundle version', entry['version'], 'SHA-256', entry['sha256'])
