"""Resource contract for the launcher selector; run with Python unittest."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / 'android/app/src/main/res'
ANDROID = '{http://schemas.android.com/apk/res/android}'
NAMES = ('ic_launcher', 'musa_chrome', 'musa_brushed', 'musa_glass', 'musa_neon', 'musa_pearl')


class AdaptiveIconsTest(unittest.TestCase):
    def test_layers_and_references(self):
        manifest = ET.parse(ROOT / 'android/app/src/main/AndroidManifest.xml')
        aliases = manifest.findall('.//activity-alias')
        self.assertTrue(set('@mipmap/' + n for n in NAMES).issubset(
            {a.get(ANDROID + 'icon') for a in aliases}))
        for name in NAMES:
            for version in (26, 33):
                with self.subTest(name=name, version=version):
                    icon = ET.parse(RES / f'mipmap-anydpi-v{version}/{name}.xml').getroot()
                    self.assertEqual(icon.tag, 'adaptive-icon')
                    self.assertEqual([child.tag for child in icon],
                                     ['background', 'foreground'] + (['monochrome'] if version == 33 else []))
                    expected = 'musa_original' if name == 'ic_launcher' else name
                    self.assertEqual(icon.find('foreground').get(ANDROID + 'drawable'), f'@drawable/{expected}_inset')
                    inset = ET.parse(RES / f'drawable-nodpi/{expected}_inset.xml').getroot()
                    image = inset.get(ANDROID + 'drawable').split('/')[-1]
                    self.assertTrue((RES / f'drawable-nodpi/{image}.png').is_file())
                    if version == 33:
                        self.assertEqual(icon.find('monochrome').get(ANDROID + 'drawable'), '@drawable/musa_monochrome_inset')
        mono = ET.parse(RES / 'drawable-nodpi/musa_monochrome_inset.xml').getroot()
        self.assertEqual(mono.get(ANDROID + 'drawable'), '@drawable/ic_notification_musa_media')
        self.assertTrue((RES / 'drawable-nodpi/ic_notification_musa_media.png').is_file())


if __name__ == '__main__':
    unittest.main()
