"""Guard the process-local Bash selection used by Android Gradle tasks."""

import unittest
from pathlib import Path


class GradleBashSelectionTest(unittest.TestCase):
    def test_override_and_default_are_used_for_both_shell_tasks(self):
        gradle = (Path(__file__).resolve().parents[1] / "android/app/build.gradle.kts").read_text()
        self.assertIn('providers.environmentVariable("MUSA_BASH_EXECUTABLE")', gradle)
        self.assertIn('.orNull?.takeIf { it.isNotBlank() } ?: "bash"', gradle)
        self.assertIn('bashExecutable,\n        "scripts/flutter_git_commit.sh"', gradle)
        self.assertIn('commandLine(bashExecutable, "scripts/build_rust_backend.sh", "android")', gradle)


if __name__ == "__main__":
    unittest.main()
