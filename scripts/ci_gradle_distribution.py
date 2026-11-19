"""Stage the verified Android Gradle ZIP and its Kotlin compiler on a CI runner."""

from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


WRAPPER_PROPERTIES = Path("android/gradle/wrapper/gradle-wrapper.properties")
PROJECT_PROPERTIES = Path("android/gradle.properties")
CACHE_DIRECTORY = "musa-gradle-distribution"
ARCHIVE_NAME = "gradle-9.8.2-all.zip"
ARCHIVE_SIZE = 264652692
# https://gradle.org/release-checksums/
ARCHIVE_SHA256 = "a1bb7e9651ef09e4cd9a62d471564e0ee23b5757e5f21fd7358d7cfc21018fdf"
DISTRIBUTION_URL = f"https://services.gradle.org/distributions/{ARCHIVE_NAME}"
RELEASE_ASSET_URL = "https://api.github.com/repos/gradle/gradle-distributions/releases/assets/656830900"
KOTLIN_COMPILER_NAME = "kotlin-compiler-embeddable-2.4.10.jar"
KOTLIN_COMPILER_MEMBER = f"gradle-9.8.2/lib/{KOTLIN_COMPILER_NAME}"
KOTLIN_COMPILER_MAVEN_PATH = Path("org/jetbrains/kotlin/kotlin-compiler-embeddable/2.4.10") / KOTLIN_COMPILER_NAME
KOTLIN_COMPILER_SIZE = 60352373
# JetBrains Kotlin release v2.4.10, asset 583808361.
KOTLIN_COMPILER_SHA256 = "9309638a2ee03e6bde9ef4b7444055a94b84ab906563675d71ff9aecb64da913"


def runner_paths(env, cwd):
    expected = {
        "RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_OS": "Linux",
        "RUNNER_ARCH": "X64",
        "GITHUB_ACTIONS": "true",
        "CI": "true",
    }
    if any(env.get(key) != value for key, value in expected.items()):
        raise ValueError("An x64 GitHub-hosted Linux runner is required")
    raw_paths = [Path(env.get(name, "")) for name in ("GITHUB_WORKSPACE", "RUNNER_TEMP")]
    if not all(path.is_absolute() for path in raw_paths):
        raise ValueError("Expected absolute GITHUB_WORKSPACE and RUNNER_TEMP paths")
    workspace, runner_temp = (path.resolve(strict=True) for path in raw_paths)
    if workspace != cwd.resolve() or not workspace.is_dir():
        raise ValueError("Run from the GitHub checkout root")
    if not runner_temp.is_dir() or workspace.is_relative_to(runner_temp) or runner_temp.is_relative_to(workspace):
        raise ValueError("RUNNER_TEMP must be a separate directory from the checkout")
    return workspace, runner_temp


def wrapper_contents(properties, archive):
    if not properties.is_file() or properties.resolve(strict=True) != properties:
        raise ValueError("Unexpected Gradle wrapper properties path")
    content = properties.read_bytes()
    lines = content.splitlines(keepends=True)
    entries = {}
    for index, line in enumerate(lines):
        text = line.rstrip(b"\r\n")
        if not text.strip() or text.lstrip().startswith((b"#", b"!")):
            continue
        match = re.fullmatch(rb"([a-zA-Z][a-zA-Z0-9]*)=(.*)", text)
        if not match or text.endswith(b"\\") or match[1] in entries:
            raise ValueError("Unexpected or duplicate Gradle wrapper property")
        entries[match[1]] = (index, match[2])

    remote_url = DISTRIBUTION_URL.replace(":", "\\:", 1).encode()
    # Flutter 3.47.8 takes the second hyphen-separated token as the Gradle version.
    parent_uri = archive.parent.as_uri().replace("-", "%2D")
    local_url = f"{parent_uri}/{archive.name}".replace(":", "\\:", 1).encode()
    index, current_url = entries.get(b"distributionUrl", (None, None))
    _, expected_hash = entries.get(b"distributionSha256Sum", (None, None))
    if current_url not in (remote_url, local_url) or expected_hash != ARCHIVE_SHA256.encode():
        raise ValueError("Gradle wrapper URL or checksum does not match the pinned release")
    line = lines[index]
    newline = line[len(line.rstrip(b"\r\n")):]
    lines[index] = b"distributionUrl=" + local_url + newline
    return content, b"".join(lines)


def verified_file(path, size, checksum):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != size:
        return False
    with path.open("rb") as archive:
        return hashlib.file_digest(archive, "sha256").hexdigest() == checksum


def project_contents(properties, maven_repo):
    if not properties.is_file() or properties.resolve(strict=True) != properties:
        raise ValueError("Unexpected Android Gradle properties path")
    content = properties.read_bytes()
    repo_path = maven_repo.as_posix()
    if any(ord(character) < 32 or ord(character) > 126 for character in repo_path):
        raise ValueError("Unexpected Maven local path encoding")
    escaped_path = repo_path.replace("\\", "\\\\")
    override = f"systemProp.maven.repo.local={escaped_path}".encode("ascii")
    existing = []
    for line in re.split(rb"\r\n|\r|\n", content):
        text = line.lstrip(b" \t\f")
        if not text or text.startswith((b"#", b"!")):
            continue
        # Keep plain keys and refuse syntax that can hide an equivalent Java Properties key.
        key = re.match(rb"[A-Za-z0-9_.-]+(?=[ \t\f:=]|$)", text)
        trailing_backslashes = len(text) - len(text.rstrip(b"\\"))
        if not key or trailing_backslashes % 2:
            raise ValueError("Ambiguous Android Gradle property with an escaped key or continued line")
        if key[0] == b"systemProp.maven.repo.local":
            existing.append(line)
    if existing and existing != [override]:
        raise ValueError("Unexpected Maven local override in Android Gradle properties")
    if existing:
        return content, content
    newline = b"\r\n" if b"\r\n" in content else b"\n"
    separator = newline if content and not content.endswith((b"\r", b"\n")) else b""
    return content, content + separator + override + newline


def replace_properties(updates):
    with ExitStack() as temporary_directories:
        pending = []
        for path, original, configured in updates:
            if original == configured:
                continue
            staging = Path(temporary_directories.enter_context(
                tempfile.TemporaryDirectory(prefix="gradle-properties-", dir=path.parent)
            ))
            replacement = staging / "configured"
            backup = staging / "original"
            mode = stat.S_IMODE(path.stat().st_mode)
            for target, content in ((replacement, configured), (backup, original)):
                with target.open("wb") as stream:
                    stream.write(content)
                    stream.flush()
                    target.chmod(mode)
                    os.fsync(stream.fileno())
            pending.append((path, original, replacement, backup))

        # A failed preflight leaves both files untouched.
        for path, original, _, _ in pending:
            if path.resolve(strict=True) != path or path.read_bytes() != original:
                raise ValueError(f"Gradle properties changed during preparation: {path.name}")

        applied = []
        try:
            for path, _, replacement, backup in pending:
                os.replace(replacement, path)
                applied.append((path, backup))
        except OSError:
            for path, backup in reversed(applied):
                try:
                    os.replace(backup, path)
                except OSError as error:
                    raise OSError(f"Could not roll back Gradle properties: {path.name}") from error
            raise


def stage_kotlin_compiler(archive, candidate):
    if verified_file(candidate, KOTLIN_COMPILER_SIZE, KOTLIN_COMPILER_SHA256):
        return
    candidate.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(candidate.parent).free < KOTLIN_COMPILER_SIZE:
        raise ValueError("Insufficient free space to stage the pinned Kotlin compiler")
    with tempfile.TemporaryDirectory(prefix="kotlin-compiler-", dir=candidate.parent) as staging:
        staged = Path(staging) / candidate.name
        try:
            with zipfile.ZipFile(archive) as distribution:
                member = distribution.getinfo(KOTLIN_COMPILER_MEMBER)
                if member.file_size != KOTLIN_COMPILER_SIZE:
                    raise ValueError("Unexpected Kotlin compiler size in the Gradle ZIP")
                with distribution.open(member) as source, staged.open("wb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
        except (zipfile.BadZipFile, KeyError) as error:
            raise ValueError("Could not read the pinned Kotlin compiler from the Gradle ZIP") from error
        if not verified_file(staged, KOTLIN_COMPILER_SIZE, KOTLIN_COMPILER_SHA256):
            raise ValueError("Kotlin compiler checksum mismatch")
        staged.replace(candidate)


def download_verified_archive(archive):
    if shutil.disk_usage(archive.parent).free < ARCHIVE_SIZE:
        raise ValueError("Insufficient free space to stage the pinned Gradle ZIP")
    sources = (
        ("Gradle distribution service", DISTRIBUTION_URL, []),
        ("GitHub release asset API", RELEASE_ASSET_URL, ["--header", "Accept: application/octet-stream"]),
    )
    with tempfile.TemporaryDirectory(prefix="gradle-download-", dir=archive.parent) as staging:
        candidate = Path(staging) / ARCHIVE_NAME
        for label, url, headers in sources:
            candidate.unlink(missing_ok=True)
            command = [
                "curl", "--disable", "--silent", "--show-error", "--fail", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "4",
                "--connect-timeout", "10", "--max-time", "120", "--retry", "2",
                "--retry-max-time", "180", "--max-filesize", str(ARCHIVE_SIZE),
                "--output", str(candidate), "--write-out", "%{http_code}", *headers, url,
            ]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=210)
            except subprocess.TimeoutExpired:
                print(f"{label} timed out")
                continue
            status = result.stdout.strip()
            if result.returncode == 0 and status == "200" and verified_file(candidate, ARCHIVE_SIZE, ARCHIVE_SHA256):
                candidate.replace(archive)
                print(f"Verified Gradle ZIP from {label}")
                return
            print(f"{label} did not yield a valid Gradle ZIP (HTTP {status or 'none'}, curl {result.returncode})")
    raise ValueError("Could not obtain the verified Gradle ZIP from the official sources")


def prepare(workspace, runner_temp):
    cache = runner_temp / CACHE_DIRECTORY
    archive = cache / ARCHIVE_NAME
    if cache.is_symlink() or (cache.exists() and not cache.is_dir()):
        raise ValueError("Unexpected Gradle cache path")
    if archive.is_symlink() or (archive.exists() and not archive.is_file()):
        raise ValueError("Unexpected Gradle archive cache path")
    maven_repo = runner_temp / "musa_kotlin_maven"
    candidate = maven_repo / KOTLIN_COMPILER_MAVEN_PATH
    if candidate.resolve() != candidate or (candidate.exists() and not candidate.is_file()):
        raise ValueError("Unexpected Kotlin compiler candidate path")
    properties = workspace / WRAPPER_PROPERTIES
    original, content = wrapper_contents(properties, archive)
    project_properties = workspace / PROJECT_PROPERTIES
    project_original, project_content = project_contents(project_properties, maven_repo)
    cache.mkdir(exist_ok=True)
    refreshed = not verified_file(archive, ARCHIVE_SIZE, ARCHIVE_SHA256)
    if refreshed:
        download_verified_archive(archive)
    else:
        print("Verified cached Gradle ZIP")
    stage_kotlin_compiler(archive, candidate)
    print("Verified Kotlin compiler Maven-local candidate")
    replace_properties((
        (properties, original, content),
        (project_properties, project_original, project_content),
    ))
    return refreshed


def main():
    try:
        workspace, runner_temp = runner_paths(os.environ, Path.cwd())
        output = Path(os.environ.get("GITHUB_OUTPUT", "")).resolve()
        if not output.is_file() or not output.is_relative_to(runner_temp):
            raise ValueError("Expected GITHUB_OUTPUT to be a file inside RUNNER_TEMP")
        refreshed = prepare(workspace, runner_temp)
        with output.open("a", encoding="utf-8") as command_file:
            print(f"refreshed={str(refreshed).lower()}", file=command_file)
    except (OSError, ValueError) as error:
        sys.exit(f"Gradle distribution: {error}")


if __name__ == "__main__":
    main()
