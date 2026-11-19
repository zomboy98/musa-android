"""Check the Android media icon. Run with Python and Pillow installed.

Set MUSA_ANDROID_ICONS_ZIP to the supplied source ZIP to additionally verify
the mask against the original artwork. The source archive is not in the repo.
"""

import io
import os
from pathlib import Path
import unittest
import zipfile

from PIL import Image, ImageChops


ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "android/app/src/main/res/drawable-nodpi/ic_notification_musa_media.png"
RESOURCE = "drawable/ic_notification_musa_media"


class MusaMediaIconTest(unittest.TestCase):
    def test_android_configuration_and_transparent_mask(self):
        runtime = (ROOT / "lib/services/music_player_runtime.dart").read_text(encoding="utf-8")
        resolver = (ROOT / "android/app/src/main/kotlin/com/zarz/mornye/MornyeApplication.kt").read_text(encoding="utf-8")
        notifications = (ROOT / "lib/services/notification_service.dart").read_text(encoding="utf-8")
        self.assertIn(f"androidNotificationIcon: '{RESOURCE}'", runtime)
        self.assertIn(f'"{RESOURCE}" -> R.drawable.ic_notification_musa_media', resolver)
        self.assertEqual(notifications.count(f"'@{RESOURCE}'"), 2)
        self.assertNotIn("ic_notification_mornye", runtime)
        self.assertNotIn("ic_notification_mornye", notifications)

        with Image.open(ICON) as icon:
            self.assertEqual((icon.mode, icon.size), ("RGBA", (96, 96)))
            alpha = icon.getchannel("A")
            self.assertEqual(alpha.getextrema(), (0, 255))
            self.assertEqual(alpha.getbbox(), (8, 18, 88, 78))
            self.assertTrue(all(icon.getchannel(c).getextrema() == (255, 255) for c in "RGB"))
            self.assertTrue(all(alpha.getpixel(p) == 0 for p in ((0, 0), (95, 0), (0, 95), (95, 95))))

    def test_mask_matches_supplied_original(self):
        archive = os.environ.get("MUSA_ANDROID_ICONS_ZIP")
        if not archive:
            self.skipTest("Set MUSA_ANDROID_ICONS_ZIP to verify against the source archive")
        with zipfile.ZipFile(archive) as source:
            original = Image.open(io.BytesIO(source.read("MUSA_icon_1024x1024.png"))).convert("L")
        cropped = original.crop((65, 165, 960, 835))
        mask = cropped.point(lambda v: max(0, min(255, (v - 40) * 255 // 170)))
        mask.thumbnail((80, 80), Image.Resampling.LANCZOS)
        expected = Image.new("L", (96, 96), 0)
        expected.paste(mask, ((96 - mask.width) // 2, (96 - mask.height) // 2))
        with Image.open(ICON) as icon:
            self.assertIsNone(ImageChops.difference(icon.getchannel("A"), expected).getbbox())


if __name__ == "__main__":
    unittest.main()
