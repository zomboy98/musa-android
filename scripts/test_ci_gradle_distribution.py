import hashlib
import io
import os
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import ci_gradle_distribution as gradle


class GradleDistributionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gradle ci test ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        self.workspace = root / "checkout"
        self.runner_temp = root / "runner temp"
        self.runner_temp.mkdir()
        self.properties = self.workspace / gradle.WRAPPER_PROPERTIES
        self.properties.parent.mkdir(parents=True)
        self.project_properties = self.workspace / "android/gradle.properties"
        self.project_original = b"# Existing configuration\r\norg.gradle.jvmargs=-Xmx2g\r\nandroid.useAndroidX=true"
        self.project_properties.write_bytes(self.project_original)
        self.archive = self.runner_temp / gradle.CACHE_DIRECTORY / gradle.ARCHIVE_NAME
        self.archive.parent.mkdir()
        self.compiler = b"synthetic compiler jar bytes"
        self.compiler_name = "kotlin-compiler-embeddable-2.4.10.jar"
        self.compiler_entry = f"gradle-9.8.2/lib/{self.compiler_name}"
        self.maven_repo = self.runner_temp / "musa_kotlin_maven"
        self.maven_jar = self.maven_repo / "org/jetbrains/kotlin/kotlin-compiler-embeddable/2.4.10" / self.compiler_name
        self.payload = self.distribution_zip(self.compiler)
        self.digest = hashlib.sha256(self.payload).hexdigest()
        for name, value in (
            ("ARCHIVE_SIZE", len(self.payload)),
            ("ARCHIVE_SHA256", self.digest),
            ("KOTLIN_COMPILER_SIZE", len(self.compiler)),
            ("KOTLIN_COMPILER_SHA256", hashlib.sha256(self.compiler).hexdigest()),
        ):
            patcher = patch.object(gradle, name, value, create=True)
            patcher.start()
            self.addCleanup(patcher.stop)
        remote_url = gradle.DISTRIBUTION_URL.replace(":", "\\:", 1)
        self.original = (
            f"distributionUrl={remote_url}\r\n"
            f"distributionSha256Sum={self.digest}\r\n"
            "distributionBase=GRADLE_USER_HOME\r\n"
        ).encode()
        self.properties.write_bytes(self.original)

    def distribution_zip(self, compiler):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr(self.compiler_entry, compiler)
            archive.writestr("gradle-9.8.2/lib/unrelated.jar", b"not needed")
        return payload.getvalue()

    def prepare(self):
        with redirect_stdout(io.StringIO()):
            gradle.prepare(self.workspace, self.runner_temp)

    def environment(self):
        return {
            "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "Linux", "RUNNER_ARCH": "X64",
            "GITHUB_ACTIONS": "true", "CI": "true", "GITHUB_WORKSPACE": str(self.workspace),
            "RUNNER_TEMP": str(self.runner_temp),
        }

    def run_step(self, output):
        env = {**self.environment(), "GITHUB_OUTPUT": str(output)}
        with patch.dict(os.environ, env), patch.object(Path, "cwd", return_value=self.workspace):
            with redirect_stdout(io.StringIO()):
                gradle.main()

    def result(self, command, body=b"", status="200", returncode=0):
        self.assertEqual(command[:2], ["curl", "--disable"])
        self.assertEqual(command[command.index("--max-filesize") + 1], str(len(self.payload)))
        self.assertEqual(command[command.index("--proto") + 1], "=https")
        self.assertEqual(command[command.index("--proto-redir") + 1], "=https")
        self.assertIn("--max-time", command)
        self.assertIn("--retry-max-time", command)
        self.assertNotIn("--netrc", command)
        path = Path(command[command.index("--output") + 1])
        self.assertTrue(path.is_relative_to(self.archive.parent))
        path.write_bytes(body)
        return subprocess.CompletedProcess(command, returncode, stdout=status)

    def assert_configured(self):
        content = self.properties.read_bytes()
        uri = self.archive.parent.as_uri().replace("-", "%2D") + "/" + self.archive.name
        self.assertIn(uri.replace(":", "\\:", 1).encode(), content)
        self.assertEqual(uri.split("-")[1], "9.8.2")
        self.assertIn(f"distributionSha256Sum={self.digest}\r\n".encode(), content)
        self.assertIn(b"distributionBase=GRADLE_USER_HOME\r\n", content)
        self.assertEqual(self.maven_jar.read_bytes(), self.compiler)
        self.assertEqual([path.name for path in self.maven_repo.rglob("*.jar")], [self.compiler_name])
        override = f"systemProp.maven.repo.local={self.maven_repo.as_posix()}\r\n".encode()
        self.assertEqual(self.project_properties.read_bytes(), self.project_original + b"\r\n" + override)

    def test_verified_cache_works_offline_and_configuration_is_idempotent(self):
        self.archive.write_bytes(self.payload)
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            self.prepare()
            self.assert_configured()
            once = self.properties.read_bytes()
            project_once = self.project_properties.read_bytes()
            self.prepare()
        self.assertEqual(self.properties.read_bytes(), once)
        self.assertEqual(self.project_properties.read_bytes(), project_once)

    def test_compiler_checksum_mismatch_never_configures_gradle(self):
        unexpected = self.distribution_zip(b"x" * len(self.compiler))
        checksum = hashlib.sha256(unexpected).hexdigest()
        properties = self.original.replace(self.digest.encode(), checksum.encode())
        self.properties.write_bytes(properties)
        self.archive.write_bytes(unexpected)
        with patch.object(gradle, "ARCHIVE_SHA256", checksum):
            with self.assertRaisesRegex(ValueError, "Kotlin compiler.*checksum"):
                self.prepare()
        self.assertFalse(self.maven_jar.exists())
        self.assertEqual(self.properties.read_bytes(), properties)
        self.assertEqual(self.project_properties.read_bytes(), self.project_original)

    def test_refuses_unexpected_maven_local_override(self):
        unexpected = self.project_original + b"\r\nsystemProp.maven.repo.local : /unexpected\r\n"
        self.project_properties.write_bytes(unexpected)
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            with self.assertRaisesRegex(ValueError, "Maven local override"):
                self.prepare()
        self.assertEqual(self.project_properties.read_bytes(), unexpected)
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_refuses_escaped_or_continued_maven_local_key(self):
        cases = (
            b"systemProp\\u002emaven.repo.local=/unexpected",
            b"systemProp.maven.repo.\\u006cocal=/unexpected",
            b"systemProp\\.maven.repo.local=/unexpected",
            b"systemProp.maven.repo.\\\r\n  local=/unexpected",
            b"systemProp.maven.repo.local=/unexpected\\\n  /continued",
        )
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            for key in cases:
                with self.subTest(key=key):
                    original = self.project_original + b"\r\n" + key + b"\r\n"
                    self.project_properties.write_bytes(original)
                    with self.assertRaisesRegex(ValueError, "Gradle property"):
                        self.prepare()
                    self.assertEqual(self.project_properties.read_bytes(), original)
                    self.assertEqual(self.properties.read_bytes(), self.original)

    def test_preserves_comments_and_escaped_values_byte_for_byte(self):
        self.archive.write_bytes(self.payload)
        original = (
            b"\t# comment with trailing backslash\\\r\n"
            b"org.gradle.jvmargs=-Dfoo=escaped\\:value\r\n"
            b"android.useAndroidX=true\r\n"
            b"ordinary.property=two trailing backslashes\\\\\r\n"
        )
        self.project_properties.write_bytes(original)
        self.prepare()
        override = f"systemProp.maven.repo.local={self.maven_repo.as_posix()}\r\n".encode()
        self.assertEqual(self.project_properties.read_bytes(), original + override)

    def test_staging_io_failure_leaves_both_properties_unchanged(self):
        self.archive.write_bytes(self.payload)
        with patch.object(gradle.os, "fsync", side_effect=[None, None, OSError("fixture staging I/O")]):
            with self.assertRaisesRegex(OSError, "fixture staging I/O"):
                self.prepare()
        self.assertEqual(self.properties.read_bytes(), self.original)
        self.assertEqual(self.project_properties.read_bytes(), self.project_original)

    def test_second_property_replace_failure_rolls_back_first_and_stops_step(self):
        self.archive.write_bytes(self.payload)
        output = self.runner_temp / "output"
        output.touch()
        real_replace = os.replace
        replaced = []

        def replace_with_failure(source, destination):
            destination = Path(destination)
            if destination in (self.properties, self.project_properties):
                replaced.append(destination)
            if destination == self.project_properties:
                raise OSError("fixture second property I/O")
            return real_replace(source, destination)

        with patch.object(gradle.os, "replace", side_effect=replace_with_failure):
            with self.assertRaisesRegex(SystemExit, "fixture second property I/O"):
                self.run_step(output)
        self.assertEqual(replaced, [self.properties, self.project_properties, self.properties])
        self.assertEqual(self.properties.read_bytes(), self.original)
        self.assertEqual(self.project_properties.read_bytes(), self.project_original)
        self.assertEqual(output.read_bytes(), b"")

    def test_refuses_symlinked_kotlin_candidate(self):
        outside = self.workspace / "not-the-candidate.jar"
        outside.write_bytes(self.compiler)
        self.maven_jar.parent.mkdir(parents=True)
        try:
            self.maven_jar.symlink_to(outside)
        except OSError as error:
            self.skipTest(f"Symlinks unavailable: {error}")
        self.archive.write_bytes(self.payload)
        with self.assertRaisesRegex(ValueError, "Kotlin compiler candidate path"):
            self.prepare()
        self.assertEqual(outside.read_bytes(), self.compiler)
        self.assertEqual(self.project_properties.read_bytes(), self.project_original)

    def test_corrupt_cache_offline_never_changes_wrapper(self):
        self.archive.write_bytes(b"x" * len(self.payload))
        with patch.object(gradle.subprocess, "run", side_effect=subprocess.TimeoutExpired("curl", 1)):
            with self.assertRaisesRegex(ValueError, "verified Gradle ZIP"):
                self.prepare()
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_valid_restore_does_not_trigger_cache_save(self):
        self.archive.write_bytes(self.payload)
        output = self.runner_temp / "output"
        output.touch()
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            self.run_step(output)
        self.assertEqual(output.read_text(), "refreshed=false\n")

    def test_corrupt_restore_refetched_with_verified_zip_triggers_cache_save(self):
        self.archive.write_bytes(b"x" * len(self.payload))
        output = self.runner_temp / "output"
        output.touch()
        with patch.object(gradle.subprocess, "run", side_effect=lambda command, **_: self.result(command, self.payload)):
            self.run_step(output)
        self.assertEqual(self.archive.read_bytes(), self.payload)
        self.assertEqual(output.read_text(), "refreshed=true\n")
        self.assert_configured()

    def test_refuses_output_outside_runner_temp(self):
        output = self.workspace / "output"
        output.touch()
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            with self.assertRaisesRegex(SystemExit, "GITHUB_OUTPUT.*RUNNER_TEMP"):
                self.run_step(output)
        self.assertEqual(output.read_bytes(), b"")
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_partial_response_uses_pinned_public_api_fallback(self):
        def fake_run(command, **kwargs):
            self.assertGreater(kwargs["timeout"], 0)
            if command[-1] == gradle.DISTRIBUTION_URL:
                return self.result(command, body=self.payload[:3], status="206")
            self.assertEqual(command[-1], gradle.RELEASE_ASSET_URL)
            self.assertEqual(command[command.index("--header") + 1], "Accept: application/octet-stream")
            return self.result(command, body=self.payload)

        with patch.object(gradle.subprocess, "run", side_effect=fake_run) as curl:
            self.prepare()
        self.assertEqual(curl.call_count, 2)
        self.assertEqual(self.archive.read_bytes(), self.payload)
        self.assert_configured()

    def test_curl_error_and_full_size_wrong_hash_fail_closed(self):
        def fake_run(command, **kwargs):
            if command[-1] == gradle.DISTRIBUTION_URL:
                return self.result(command, status="504", returncode=22)
            return self.result(command, body=b"x" * len(self.payload))

        with patch.object(gradle.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "verified Gradle ZIP"):
                self.prepare()
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.properties.read_bytes(), self.original)
        self.assertEqual(list(self.archive.parent.iterdir()), [])

    def test_short_successful_response_cannot_be_cached(self):
        def fake_run(command, **kwargs):
            return self.result(command, body=self.payload[:3])

        with patch.object(gradle.subprocess, "run", side_effect=fake_run) as curl:
            with self.assertRaisesRegex(ValueError, "verified Gradle ZIP"):
                self.prepare()
        self.assertEqual(curl.call_count, 2)
        self.assertFalse(self.archive.exists())
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_low_space_refuses_download(self):
        with patch.object(gradle.shutil, "disk_usage", return_value=SimpleNamespace(free=len(self.payload) - 1)):
            with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
                with self.assertRaisesRegex(ValueError, "Insufficient free space"):
                    self.prepare()
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_rejects_unexpected_properties_before_any_network(self):
        cases = (
            self.original.replace(b"services.gradle.org", b"unexpected.invalid"),
            self.original.replace(self.digest.encode(), b"0" * 64),
            self.original + b"distributionUrl : https://unexpected.invalid/gradle.zip\r\n",
            self.original + b"distributionSha256Sum=" + self.digest.encode() + b"\r\n",
        )
        with patch.object(gradle.subprocess, "run", side_effect=AssertionError("unexpected network")):
            for content in cases:
                with self.subTest(content=content):
                    self.properties.write_bytes(content)
                    with self.assertRaisesRegex(ValueError, "Gradle wrapper"):
                        self.prepare()
                    self.assertEqual(self.properties.read_bytes(), content)

    def test_rejects_cache_symlink(self):
        outside = self.workspace / "not-a-cache.zip"
        outside.write_bytes(self.payload)
        try:
            self.archive.symlink_to(outside)
        except OSError as error:
            self.skipTest(f"Symlinks unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "cache path"):
            self.prepare()
        self.assertEqual(outside.read_bytes(), self.payload)
        self.assertEqual(self.properties.read_bytes(), self.original)

    def test_rejects_symlinked_wrapper_properties(self):
        outside = self.runner_temp / "not-wrapper.properties"
        outside.write_bytes(self.original)
        self.properties.unlink()
        try:
            self.properties.symlink_to(outside)
        except OSError as error:
            self.skipTest(f"Symlinks unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "Gradle wrapper properties path"):
            self.prepare()
        self.assertEqual(outside.read_bytes(), self.original)

    def test_runner_guard_and_paths(self):
        env = self.environment()
        self.assertEqual(gradle.runner_paths(env, self.workspace), (self.workspace, self.runner_temp))
        with self.assertRaisesRegex(ValueError, "GitHub-hosted"):
            gradle.runner_paths({**env, "RUNNER_ENVIRONMENT": "self-hosted"}, self.workspace)
        with self.assertRaisesRegex(ValueError, "checkout root"):
            gradle.runner_paths(env, self.runner_temp)
        with self.assertRaisesRegex(ValueError, "separate"):
            gradle.runner_paths({**env, "RUNNER_TEMP": str(self.workspace)}, self.workspace)


if __name__ == "__main__":
    unittest.main()
