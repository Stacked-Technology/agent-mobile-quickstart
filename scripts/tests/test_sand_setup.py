import os
import platform
import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "update_sand.sh"
RUNNER_SCRIPT = SCRIPT.parent / "setup_sand_github_runner.sh"
PUBLIC_FORK = "https://github.com/Stacked-Technology/sand.git"
PINNED_REVISION = "c1632d93ce0b63ae52cc28a03d31eaff4b2c82fa"


def clean_environment():
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("SAND_")
    }


class SandSetupScriptTests(unittest.TestCase):
    def test_plan_uses_the_pinned_public_fork(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=clean_environment(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(PUBLIC_FORK, result.stdout)
        self.assertIn(PINNED_REVISION, result.stdout)

    def test_plan_accepts_a_different_pinned_public_fork(self):
        environment = clean_environment()
        environment.update(
            {
                "SAND_SOURCE_REPOSITORY": "https://github.com/example/sand.git",
                "SAND_REVISION": "0123456789abcdef0123456789abcdef01234567",
                "SAND_SOURCE_DIR": "/tmp/example-sand-source",
                "SAND_INSTALL_PATH": "/tmp/example-sand-bin/sand",
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://github.com/example/sand.git", result.stdout)
        self.assertIn("0123456789abcdef0123456789abcdef01234567", result.stdout)

    def test_plan_requires_source_and_revision_overrides_together(self):
        environment = clean_environment()
        environment["SAND_SOURCE_REPOSITORY"] = "https://github.com/example/sand.git"
        result = subprocess.run(
            ["bash", str(SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("together", result.stderr)

    def test_plan_rejects_an_unpinned_or_non_github_source(self):
        environment = clean_environment()
        environment.update(
            {
                "SAND_SOURCE_REPOSITORY": "https://example.com/sand.git",
                "SAND_REVISION": PINNED_REVISION,
            }
        )
        result = subprocess.run(
            ["bash", str(SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTPS GitHub repository", result.stderr)

    def test_plan_accepts_the_runner_script_binary_alias(self):
        environment = clean_environment()
        environment["SAND_BIN"] = "/tmp/example-sand-bin/sand"
        result = subprocess.run(
            ["bash", str(SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/tmp/example-sand-bin/sand", result.stdout)

    def test_runner_setup_uses_the_same_default_revision(self):
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=clean_environment(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(PUBLIC_FORK, result.stdout)
        self.assertIn(PINNED_REVISION, result.stdout)

    def test_runner_plan_defaults_to_organization_scope(self):
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=clean_environment(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scope:         organization", result.stdout)
        self.assertIn("automatic organization discovery", result.stdout)

    def test_runner_plan_accepts_organization_exclusions(self):
        environment = clean_environment()
        environment["SAND_EXCLUDE_REPOSITORIES"] = "archived-app,legacy-app"
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exclusions:    archived-app,legacy-app", result.stdout)

    def test_runner_setup_accepts_a_different_pinned_public_fork(self):
        environment = clean_environment()
        environment.update(
            {
                "SAND_SOURCE_REPOSITORY": "https://github.com/example/sand.git",
                "SAND_REVISION": "0123456789abcdef0123456789abcdef01234567",
            }
        )
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://github.com/example/sand.git", result.stdout)
        self.assertIn("0123456789abcdef0123456789abcdef01234567", result.stdout)

    def test_runner_setup_requires_source_and_revision_overrides_together(self):
        environment = clean_environment()
        environment["SAND_REVISION"] = "0123456789abcdef0123456789abcdef01234567"
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("together", result.stderr)

    def test_runner_plan_rejects_a_repository_owner_mismatch(self):
        environment = clean_environment()
        environment.update(
            {
                "SAND_REPOSITORY_SCOPE": "selected",
                "SAND_GITHUB_ORGANIZATION": "example-org",
                "SAND_GITHUB_REPOSITORY": "other-org/example-app",
            }
        )
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository owner", result.stderr)

    def test_runner_plan_rejects_repository_with_organization_scope(self):
        environment = clean_environment()
        environment.update(
            {
                "SAND_GITHUB_ORGANIZATION": "example-org",
                "SAND_GITHUB_REPOSITORY": "example-org/example-app",
            }
        )
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "plan"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires SAND_REPOSITORY_SCOPE=selected", result.stderr)

    def test_runner_render_is_read_only_and_uses_app_placeholders(self):
        if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
            self.skipTest("Sand rendering is macOS Apple Silicon only")
        environment = clean_environment()
        environment.update(
            {
                "SAND_GITHUB_ORGANIZATION": "example-org",
                "SAND_GITHUB_APP_ID": "12345",
                "SAND_VM_IMAGE": f"ghcr.io/example/image@sha256:{'0' * 64}",
                "SAND_RUNNER_NAME": "mobile-sandbox-host-01",
            }
        )
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "render"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("organization: example-org", result.stdout)
        self.assertIn("repositoryScope: organization", result.stdout)
        self.assertIn("runnerGroup: mobile-sandbox", result.stdout)
        self.assertIn("softnetBlock: \"@host\"", result.stdout)

    def test_runner_selected_scope_render_uses_repository_allowlist(self):
        if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
            self.skipTest("Sand rendering is macOS Apple Silicon only")
        environment = clean_environment()
        environment.update(
            {
                "SAND_REPOSITORY_SCOPE": "selected",
                "SAND_GITHUB_ORGANIZATION": "example-org",
                "SAND_GITHUB_REPOSITORY": "example-org/example-app",
                "SAND_GITHUB_APP_ID": "12345",
                "SAND_VM_IMAGE": f"ghcr.io/example/image@sha256:{'0' * 64}",
                "SAND_RUNNER_NAME": "mobile-sandbox-host-01",
            }
        )
        result = subprocess.run(
            ["bash", str(RUNNER_SCRIPT), "render"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repositoryScope: selected", result.stdout)
        self.assertIn("        - example-app", result.stdout)

    def test_runner_validate_checks_hermetic_binary_provenance(self):
        if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
            self.skipTest("Sand validation is macOS Apple Silicon only")
        required_commands = ("gh", "jq", "plutil", "launchctl", "shasum", "install", "tart", "softnet", "sshpass", "ssh")
        if any(shutil.which(command) is None for command in required_commands):
            self.skipTest("host does not have the Sand validation prerequisites")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            binary = root / "sand"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            (root / "sand.provenance").write_text(
                f"{PINNED_REVISION} {binary_sha} source={PUBLIC_FORK} "
                f"resolved_sha256={'0' * 64} toolchain_sha256={'1' * 64}\n"
            )
            (root / "sand.provenance").chmod(0o644)
            key = root / "github-app.pem"
            key.write_text("placeholder")
            key.chmod(0o600)
            environment = clean_environment()
            environment.update(
                {
                    "SAND_GITHUB_ORGANIZATION": "example-org",
                    "SAND_GITHUB_APP_ID": "12345",
                    "SAND_GITHUB_APP_KEY_PATH": str(key),
                    "SAND_VM_IMAGE": f"ghcr.io/example/image@sha256:{'0' * 64}",
                    "SAND_RUNNER_NAME": "mobile-sandbox-host-01",
                    "SAND_BIN": str(binary),
                    "SAND_INSTALL_PATH": str(binary),
                    "SAND_CONFIG_PATH": str(root / "mobile-runner.yml"),
                    "SAND_LAUNCH_AGENT_PATH": str(root / "mobile-runner.plist"),
                }
            )
            result = subprocess.run(
                ["bash", str(RUNNER_SCRIPT), "validate"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated", result.stdout)

    def test_install_requires_explicit_apply(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "install"],
            check=False,
            capture_output=True,
            text=True,
            env=clean_environment(),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--apply", result.stderr)

    def test_install_accepts_current_swift_version_output_before_fetching(self):
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            self.skipTest("Sand installation is macOS Apple Silicon only")
        macos_version = subprocess.run(
            ["sw_vers", "-productVersion"], check=False, capture_output=True, text=True
        ).stdout.strip()
        if not macos_version or int(macos_version.split(".", 1)[0]) < 15 or os.geteuid() == 0:
            self.skipTest("host does not meet the Sand installation preflight")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_bin = Path(temporary_directory) / "bin"
            fake_bin.mkdir()
            fake_git = fake_bin / "git"
            fake_git.write_text("#!/bin/sh\nexit 42\n")
            fake_git.chmod(0o755)
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'swift-driver version: 1.0 Apple Swift version 6.3.3 (swiftlang)'\n"
            )
            fake_swift.chmod(0o755)
            environment = clean_environment()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "SAND_SOURCE_DIR": str(Path(temporary_directory) / "source"),
                    "SAND_INSTALL_PATH": str(Path(temporary_directory) / "bin" / "sand"),
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT), "install", "--apply"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("Swift 6.2 or newer", result.stderr)


if __name__ == "__main__":
    unittest.main()
