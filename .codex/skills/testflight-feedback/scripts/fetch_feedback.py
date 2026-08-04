#!/usr/bin/env python3
"""Safely fetch, track, and explicitly archive private TestFlight feedback."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


SKILL_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SKILL_ROOT.parents[2]
CONFIG_ROOT = SKILL_ROOT / "config"
PRIVATE_OUTPUT_ROOT = REPOSITORY_ROOT / "tmp" / "testflight-feedback"
SETTINGS_PATH = CONFIG_ROOT / "settings.json"
ALLOWLIST_PATH = CONFIG_ROOT / "allowed-emails.json"
BASELINE_PATH = CONFIG_ROOT / "baseline.json"
HANDLED_PATH = CONFIG_ROOT / "handled-feedback.json"
LOCK_PATH = CONFIG_ROOT / ".handled-feedback.lock"

BRANCH_PREFIX = "agent/testflight-feedback-"
SUBMISSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
FINGERPRINT_PATTERN = re.compile(r"^[0-9a-f]{64}$")
RUN_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}\.[0-9]{6}Z$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
PROFILE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:@/-]{0,127}$")
ISO_PLACEHOLDER = "<"
MAX_RECORDS = 100
MAX_PAGES = 100
PAGE_SIZE = 25
MAX_RECORD_BYTES = 1024 * 1024
MAX_SCREENSHOT_BYTES = 25 * 1024 * 1024
MAX_SCREENSHOTS = 200
MAX_RUN_BYTES = 250 * 1024 * 1024
MAX_JSON_RESPONSE_BYTES = 32 * 1024 * 1024
SCREENSHOT_HOST = "tf-feedback.itunes.apple.com"
GITHUB_HOST = "github.com"
PENDING_STATUS = "- Deletion status: pending confirmation."
CONFIRMED_MARKER = "<!-- testflight-feedback-archive: confirmed -->"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError("command-line arguments are invalid")


def _strict_object(path: Path) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        output: dict[str, Any] = {}
        for key, value in pairs:
            if key in output:
                raise ValueError("configuration contains duplicate keys")
            output[key] = value
        return output

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except FileNotFoundError as error:
        raise ValueError(f"missing local configuration: {path.name}; run init_testflight_feedback.sh") from error
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid local configuration: {path.name}") from error
    if not isinstance(value, dict):
        raise ValueError(f"configuration must be an object: {path.name}")
    return value


def _non_placeholder(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or ISO_PLACEHOLDER in value or ">" in value:
        raise ValueError(f"{label} is not configured")
    return value.strip()


def _setting(name: str, value: Any, environment_name: str | None = None) -> str:
    override = os.getenv(environment_name) if environment_name else None
    return _non_placeholder(override if override else value, name)


def load_settings() -> dict[str, str]:
    value = _strict_object(SETTINGS_PATH)
    if value.get("schema_version") != 1:
        raise ValueError("settings.json has an unsupported schema version")
    app_id = _setting("app_id", value.get("app_id"), "TESTFLIGHT_APP_ID")
    read_profile = _setting("read_profile", value.get("read_profile"), "TESTFLIGHT_READ_PROFILE")
    delete_profile = _setting("delete_profile", value.get("delete_profile"), "TESTFLIGHT_DELETE_PROFILE")
    repository = _setting("github_repository", value.get("github_repository"), "TESTFLIGHT_GITHUB_REPOSITORY")
    base_branch = _setting("base_branch", value.get("base_branch"), "TESTFLIGHT_BASE_BRANCH")
    github_host = _setting("github_host", value.get("github_host"), "TESTFLIGHT_GITHUB_HOST")
    if not re.fullmatch(r"[0-9]+", app_id):
        raise ValueError("app_id must be numeric")
    if not PROFILE_PATTERN.fullmatch(read_profile) or not PROFILE_PATTERN.fullmatch(delete_profile):
        raise ValueError("App Store Connect profile name contains unsupported characters")
    if read_profile == delete_profile:
        raise ValueError("read_profile and delete_profile must be different profiles")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise ValueError("github_repository must have the form OWNER/REPOSITORY")
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", base_branch):
        raise ValueError("base_branch contains unsupported characters")
    if github_host != GITHUB_HOST or not re.fullmatch(r"[A-Za-z0-9.-]+", github_host):
        raise ValueError("only github.com is supported by this helper")
    return {
        "app_id": app_id,
        "read_profile": read_profile,
        "delete_profile": delete_profile,
        "github_repository": repository,
        "base_branch": base_branch,
        "github_host": github_host,
    }


def normalize_email(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    result = value.strip().casefold()
    if (
        not result
        or len(result) > 254
        or result.count("@") != 1
        or any(character.isspace() for character in result)
        or ISO_PLACEHOLDER in result
    ):
        return None
    return result


def load_allowed_email_fingerprints() -> set[str]:
    value = _strict_object(ALLOWLIST_PATH)
    emails = value.get("emails")
    if value.get("schema_version") != 1 or not isinstance(emails, list) or not emails:
        raise ValueError("allowed-emails.json must contain at least one approved email")
    normalized = [normalize_email(item) for item in emails]
    if any(item is None for item in normalized) or len(set(normalized)) != len(emails):
        raise ValueError("allowed-emails.json contains an invalid or duplicate email")
    return {hashlib.sha256(item.encode("utf-8")).hexdigest() for item in normalized if item}


def parse_timestamp(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("feedback timestamp is invalid")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValueError("feedback timestamp is invalid") from error
    if parsed.tzinfo is None:
        raise ValueError("feedback timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def load_baseline() -> datetime:
    value = _strict_object(BASELINE_PATH).get("ignore_created_at_or_before")
    if isinstance(value, str) and ISO_PLACEHOLDER in value:
        raise ValueError("baseline.json must contain an explicit app-specific UTC timestamp")
    return parse_timestamp(value)


def load_handled() -> set[str]:
    value = _strict_object(HANDLED_PATH)
    fingerprints = value.get("submission_id_sha256")
    if value.get("schema_version") != 1 or not isinstance(fingerprints, list):
        raise ValueError("handled-feedback.json has an invalid schema")
    if not all(isinstance(item, str) and FINGERPRINT_PATTERN.fullmatch(item) for item in fingerprints):
        raise ValueError("handled-feedback.json contains an invalid fingerprint")
    return set(fingerprints)


def submission_id(record: dict[str, Any]) -> str:
    value = record.get("id")
    if not isinstance(value, str) or not SUBMISSION_ID_PATTERN.fullmatch(value):
        raise ValueError("feedback submission has an invalid ID")
    return value


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def record_attributes(record: dict[str, Any]) -> dict[str, Any]:
    value = record.get("attributes")
    if not isinstance(value, dict):
        raise ValueError("feedback submission has invalid attributes")
    return value


def is_eligible(record: dict[str, Any], allowed: set[str]) -> bool:
    email = normalize_email(record_attributes(record).get("email"))
    return bool(email and fingerprint(email) in allowed)


def _command_environment(**updates: str) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update(updates)
    environment.pop("ASC_API_KEY", None)
    environment.pop("ASC_API_ISSUER", None)
    environment.pop("ASC_API_PRIVATE_KEY", None)
    return environment


def asc_json(profile: str, arguments: list[str]) -> dict[str, Any]:
    command = ["asc", "--profile", profile, *arguments]
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=REPOSITORY_ROOT,
            env=_command_environment(ASC_TELEMETRY_DISABLED="1"),
            text=True,
            timeout=120,
        )
    except FileNotFoundError as error:
        raise RuntimeError("missing required command: asc") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("asc command timed out") from error
    if len(result.stdout.encode("utf-8")) > MAX_JSON_RESPONSE_BYTES:
        raise RuntimeError("asc response exceeded the safety limit")
    if result.returncode != 0:
        raise RuntimeError("asc command failed; inspect auth status and profile permissions")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("asc returned invalid JSON") from error
    if not isinstance(value, dict):
        raise RuntimeError("asc returned a non-object JSON response")
    return value


def gh_json(settings: dict[str, str], endpoint: str, *, method: str | None = None, fields: list[str] | None = None) -> Any:
    command = ["gh", "api", "--hostname", settings["github_host"]]
    if method:
        command.extend(["--method", method])
    command.append(endpoint)
    for field in fields or []:
        command.extend(["-f", field])
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=REPOSITORY_ROOT,
            env=_command_environment(GH_PAGER="cat", GH_PROMPT_DISABLED="1"),
            text=True,
            timeout=90,
        )
    except FileNotFoundError as error:
        raise RuntimeError("missing required command: gh") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("GitHub API request timed out") from error
    if len(result.stdout.encode("utf-8")) > MAX_JSON_RESPONSE_BYTES:
        raise RuntimeError("GitHub response exceeded the safety limit")
    if result.returncode != 0:
        raise RuntimeError("GitHub API request failed; inspect gh auth status")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("GitHub returned invalid JSON") from error


def current_branch_and_head() -> tuple[str, str]:
    try:
        branch = subprocess.run(["git", "branch", "--show-current"], check=True, capture_output=True, text=True, cwd=REPOSITORY_ROOT).stdout.strip()
        head = subprocess.run(["git", "rev-parse", "HEAD"], check=True, capture_output=True, text=True, cwd=REPOSITORY_ROOT).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("could not inspect the current Git reservation") from error
    if not branch.startswith(BRANCH_PREFIX) or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise RuntimeError("run from a pushed agent/testflight-feedback-* branch")
    return branch, head


def _flatten_pages(value: Any) -> list[Any]:
    if isinstance(value, list) and all(isinstance(page, list) for page in value):
        output: list[Any] = []
        for page in value:
            output.extend(page)
        return output
    return value if isinstance(value, list) else []


def assert_reservation(settings: dict[str, str], expected_pr: int | None = None) -> tuple[int, str]:
    branch, head = current_branch_and_head()
    owner = settings["github_repository"].split("/", 1)[0]
    endpoint = (
        f"repos/{settings['github_repository']}/pulls?state=open&base="
        f"{urllib.parse.quote(settings['base_branch'])}&head={urllib.parse.quote(owner + ':' + branch)}&per_page=100"
    )
    records = _flatten_pages(gh_json(settings, endpoint))
    matching: list[dict[str, Any]] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        head_data = record.get("head") or {}
        base_data = record.get("base") or {}
        head_repo = head_data.get("repo") or {}
        base_repo = base_data.get("repo") or {}
        if (
            head_data.get("ref") == branch
            and head_data.get("sha") == head
            and base_data.get("ref") == settings["base_branch"]
            and head_repo.get("full_name") == settings["github_repository"]
            and base_repo.get("full_name") == settings["github_repository"]
            and record.get("draft") is True
        ):
            matching.append(record)
    if len(matching) != 1:
        raise RuntimeError("one open draft PR must reserve the current pushed feedback branch")
    pr_number = matching[0].get("number")
    if not isinstance(pr_number, int) or pr_number < 1:
        raise RuntimeError("feedback reservation PR number is invalid")
    if expected_pr is not None and expected_pr != pr_number:
        raise RuntimeError("the selected PR does not match the current feedback reservation")
    return pr_number, head


def feedback_records(response: dict[str, Any]) -> list[dict[str, Any]]:
    data = response.get("data")
    if not isinstance(data, list) or not all(isinstance(record, dict) for record in data):
        raise ValueError("asc feedback response has an invalid data array")
    return data


def list_feedback(settings: dict[str, str], cutoff: datetime | None, handled: set[str], include_handled: bool, allowed: set[str]) -> list[dict[str, Any]]:
    arguments = [
        "testflight", "feedback", "list", "--app", settings["app_id"],
        "--sort=-createdDate", "--limit", str(PAGE_SIZE), "--include-screenshots", "--output", "json",
    ]
    result: list[dict[str, Any]] = []
    visited_next: set[str] = set()
    previous_created: datetime | None = None
    for _ in range(MAX_PAGES):
        response = asc_json(settings["read_profile"], arguments)
        for record in feedback_records(response):
            created = parse_timestamp(record_attributes(record).get("createdDate"))
            if previous_created is not None and created > previous_created:
                raise ValueError("asc feedback response is not sorted newest-first")
            previous_created = created
            if cutoff is not None and created <= cutoff:
                return result
            if not is_eligible(record, allowed):
                continue
            if not include_handled and fingerprint(submission_id(record)) in handled:
                continue
            if len(json.dumps(record).encode("utf-8")) > MAX_RECORD_BYTES:
                raise RuntimeError("a feedback record exceeds the safety limit")
            if len(result) >= MAX_RECORDS:
                raise RuntimeError("feedback run exceeds the record safety limit")
            result.append(record)
        links = response.get("links") or {}
        if not isinstance(links, dict):
            raise ValueError("asc feedback response has invalid pagination links")
        next_url = links.get("next")
        if not next_url:
            return result
        if not isinstance(next_url, str) or not next_url.startswith("https://api.appstoreconnect.apple.com/"):
            raise ValueError("asc feedback pagination returned an unapproved URL")
        if next_url in visited_next:
            raise RuntimeError("asc feedback pagination repeated a URL")
        visited_next.add(next_url)
        arguments = ["testflight", "feedback", "list", "--next", next_url, "--include-screenshots", "--output", "json"]
    raise RuntimeError("feedback pagination exceeded the safety limit")


def screenshot_records(record: dict[str, Any]) -> list[dict[str, Any]]:
    screenshots = record_attributes(record).get("screenshots") or []
    if not isinstance(screenshots, list) or not all(isinstance(item, dict) for item in screenshots):
        raise ValueError("feedback screenshots must be an array of objects")
    return screenshots


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=False)


def ensure_private_output_root() -> None:
    temporary_root = REPOSITORY_ROOT / "tmp"
    for path in (temporary_root, PRIVATE_OUTPUT_ROOT):
        if path.is_symlink():
            raise ValueError("private feedback output path must not be a symbolic link")
        if path.exists() and not path.is_dir():
            raise ValueError("private feedback output path must be a directory")
        path.mkdir(mode=0o700, exist_ok=True)
        if path.is_symlink():
            raise ValueError("private feedback output path must not be a symbolic link")
    if PRIVATE_OUTPUT_ROOT.resolve() != PRIVATE_OUTPUT_ROOT:
        raise ValueError("private feedback output path must remain inside the repository")


def _write_private_json(path: Path, value: Any) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _download_screenshot(url: Any, destination: Path, remaining_bytes: int) -> int:
    if not isinstance(url, str):
        raise ValueError("feedback screenshot URL is invalid")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != SCREENSHOT_HOST or parsed.port is not None:
        raise ValueError("feedback screenshot URL is not an approved HTTPS host")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "mobile-agent-quickstart/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urllib.parse.urlparse(response.geturl())
            if final.scheme != "https" or final.hostname != SCREENSHOT_HOST or final.port is not None:
                raise ValueError("feedback screenshot redirect left the approved host")
            content_type = response.headers.get_content_type()
            if not content_type.startswith("image/"):
                raise ValueError("feedback screenshot has an unsupported content type")
            length = response.headers.get("Content-Length")
            if length and (not length.isdigit() or int(length) > min(MAX_SCREENSHOT_BYTES, remaining_bytes)):
                raise ValueError("feedback screenshot exceeds the safety limit")
            written = 0
            with destination.open("wb") as output:
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > min(MAX_SCREENSHOT_BYTES, remaining_bytes):
                        raise ValueError("feedback screenshot exceeds the safety limit")
                    output.write(chunk)
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    destination.chmod(0o600)
    return written


def fetch(args: argparse.Namespace) -> int:
    settings = load_settings()
    assert_reservation(settings)
    validate_profile(settings["read_profile"])
    allowed = load_allowed_email_fingerprints()
    cutoff = None if args.include_baseline else load_baseline()
    records = list_feedback(settings, cutoff, load_handled(), args.include_handled, allowed)
    screenshot_count = sum(len(screenshot_records(record)) for record in records)
    if screenshot_count > MAX_SCREENSHOTS:
        raise RuntimeError("feedback run exceeds the screenshot safety limit")
    if not records:
        print(json.dumps({"outputDirectory": None, "feedbackCount": 0, "privacy": "No private artifacts were written."}, indent=2))
        return 0
    ensure_private_output_root()
    run_directory = PRIVATE_OUTPUT_ROOT / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    _private_directory(run_directory)
    total_bytes = 0
    manifest_records: list[dict[str, Any]] = []
    try:
        for record in records:
            identifier = submission_id(record)
            submission_directory = run_directory / identifier
            _private_directory(submission_directory)
            _write_private_json(submission_directory / "feedback.json", record)
            total_bytes += len(json.dumps(record).encode("utf-8"))
            screenshot_names: list[str] = []
            screenshot_directory = submission_directory / "screenshots"
            screenshots = screenshot_records(record)
            if screenshots and not args.no_screenshots:
                _private_directory(screenshot_directory)
                for index, screenshot in enumerate(screenshots, start=1):
                    name = f"{index:02d}"
                    total_bytes += _download_screenshot(screenshot.get("url"), screenshot_directory / name, MAX_RUN_BYTES - total_bytes)
                    screenshot_names.append(name)
            manifest_records.append({
                "submissionDirectory": identifier,
                "createdDate": record_attributes(record).get("createdDate"),
                "screenshots": screenshot_names,
            })
            if total_bytes > MAX_RUN_BYTES:
                raise RuntimeError("feedback run exceeds the aggregate byte safety limit")
        _write_private_json(run_directory / "manifest.json", {
            "schema_version": 1,
            "fetchedAt": datetime.now(timezone.utc).isoformat(),
            "appId": settings["app_id"],
            "profile": settings["read_profile"],
            "feedbackCount": len(records),
            "records": manifest_records,
        })
    except Exception:
        shutil.rmtree(run_directory, ignore_errors=True)
        raise
    print(json.dumps({"outputDirectory": str(run_directory), "feedbackCount": len(records), "privacy": "Private artifacts remain under gitignored tmp/testflight-feedback/."}, indent=2))
    return 0


def _feedback_input(path: Path, settings: dict[str, str]) -> dict[str, Any]:
    ensure_private_output_root()
    private_root = PRIVATE_OUTPUT_ROOT.resolve(strict=True)
    if path.is_symlink():
        raise ValueError("feedback input must not be a symbolic link")
    candidate = path.resolve(strict=True)
    try:
        relative = candidate.relative_to(private_root)
    except ValueError as error:
        raise ValueError("feedback input must be under tmp/testflight-feedback/") from error
    if len(relative.parts) != 3 or not RUN_PATTERN.fullmatch(relative.parts[0]) or not SUBMISSION_ID_PATTERN.fullmatch(relative.parts[1]) or relative.parts[2] != "feedback.json":
        raise ValueError("feedback input has an invalid private path")
    run_directory = private_root / relative.parts[0]
    submission_directory = run_directory / relative.parts[1]
    if any(item.is_symlink() for item in (run_directory, submission_directory, candidate)):
        raise ValueError("feedback input must not contain symbolic links")
    manifest = _strict_object(run_directory / "manifest.json")
    if manifest.get("appId") != settings["app_id"] or manifest.get("profile") != settings["read_profile"]:
        raise ValueError("feedback input provenance does not match local settings")
    manifest_records = manifest.get("records")
    if not isinstance(manifest_records, list) or not any(isinstance(item, dict) and item.get("submissionDirectory") == relative.parts[1] for item in manifest_records):
        raise ValueError("feedback input is not present in its private manifest")
    record = _strict_object(candidate)
    if submission_id(record) != relative.parts[1]:
        raise ValueError("feedback input ID does not match its private directory")
    return record


@contextlib.contextmanager
def ledger_lock() -> Iterator[None]:
    CONFIG_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with LOCK_PATH.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def write_handled(fingerprints: set[str]) -> None:
    _write_private_json(HANDLED_PATH, {"schema_version": 1, "submission_id_sha256": sorted(fingerprints)})
    HANDLED_PATH.chmod(0o644)


def assert_handled_ledger_committed() -> None:
    try:
        result = subprocess.run(["git", "status", "--porcelain", "--", str(HANDLED_PATH.relative_to(REPOSITORY_ROOT))], check=True, capture_output=True, text=True, cwd=REPOSITORY_ROOT)
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("could not inspect the handled feedback ledger") from error
    if result.stdout.strip():
        raise RuntimeError("commit and push handled-feedback.json before archiving")


def mark_handled(args: argparse.Namespace) -> int:
    settings = load_settings()
    assert_reservation(settings)
    allowed = load_allowed_email_fingerprints()
    with ledger_lock():
        fingerprints = load_handled()
        for path_string in args.feedback:
            record = _feedback_input(Path(path_string), settings)
            if not is_eligible(record, allowed):
                raise ValueError("feedback input is not eligible")
            fingerprints.add(fingerprint(submission_id(record)))
        write_handled(fingerprints)
    print(json.dumps({"handledFingerprints": len(fingerprints)}, indent=2))
    return 0


def archive_marker(args: argparse.Namespace) -> int:
    settings = load_settings()
    pr_number, head = assert_reservation(settings, args.pr_number)
    assert_handled_ledger_committed()
    allowed = load_allowed_email_fingerprints()
    records = [_feedback_input(Path(path), settings) for path in args.feedback]
    handled = load_handled()
    for record in records:
        if not is_eligible(record, allowed) or fingerprint(submission_id(record)) not in handled:
            raise ValueError("every selected feedback record must be eligible and handled")
    targets = ",".join(sorted(fingerprint(submission_id(record)) for record in records))
    token = hashlib.sha256(f"{head}\0{pr_number}\0{targets}".encode("utf-8")).hexdigest()
    marker = f"<!-- testflight-feedback-archive: pending head={head} targets={targets} nonce={token} -->"
    print(json.dumps({"pendingCommentMarker": marker, "pendingCommentStatus": PENDING_STATUS}, indent=2))
    return 0


def validate_profile(profile: str) -> None:
    asc_json(profile, ["auth", "status", "--output", "json", "--validate"])


def assert_pending_comment(settings: dict[str, str], pr_number: int, marker: str) -> None:
    comments = gh_json(settings, f"repos/{settings['github_repository']}/issues/{pr_number}/comments?per_page=100")
    if not isinstance(comments, list):
        raise RuntimeError("GitHub returned invalid pull request comments")
    actor = gh_json(settings, "user")
    actor_login = actor.get("login") if isinstance(actor, dict) else None
    if not isinstance(actor_login, str) or not actor_login:
        raise RuntimeError("GitHub current user could not be validated")
    matching_comments = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        body = comment.get("body")
        author = comment.get("user")
        author_login = author.get("login") if isinstance(author, dict) else None
        if (
            isinstance(body, str)
            and body.splitlines()
            and body.splitlines()[0] == marker
            and PENDING_STATUS in body.splitlines()
            and author_login == actor_login
        ):
            matching_comments.append(comment)
    if len(matching_comments) != 1:
        raise RuntimeError("the exact pending archive marker comment is missing")


def assert_github_write_access(settings: dict[str, str]) -> None:
    repository = gh_json(settings, f"repos/{settings['github_repository']}")
    permissions = repository.get("permissions") if isinstance(repository, dict) else None
    if not isinstance(permissions, dict) or permissions.get("push") is not True:
        raise RuntimeError("current GitHub identity does not have repository push/comment permission")


def archive_receipt_path(token: str) -> Path:
    ensure_private_output_root()
    if not FINGERPRINT_PATTERN.fullmatch(token):
        raise ValueError("archive receipt token is invalid")
    return PRIVATE_OUTPUT_ROOT / f"archive-receipt-{token}.json"


def load_archive_receipt(path: Path, head: str, pr_number: int, targets: list[str]) -> dict[str, Any]:
    if not path.exists():
        value = {
            "schema_version": 1,
            "head": head,
            "pr": pr_number,
            "targets": sorted(targets),
            "completedTargets": [],
            "status": "pending",
        }
        _write_private_json(path, value)
        return value
    value = _strict_object(path)
    completed = value.get("completedTargets")
    if (
        value.get("schema_version") != 1
        or value.get("head") != head
        or value.get("pr") != pr_number
        or value.get("targets") != sorted(targets)
        or not isinstance(completed, list)
        or not all(isinstance(item, str) and FINGERPRINT_PATTERN.fullmatch(item) for item in completed)
        or not set(completed).issubset(set(targets))
    ):
        raise RuntimeError("archive receipt does not match the current PR and feedback set")
    return value


def delete_feedback(profile: str, records: list[dict[str, Any]], receipt_path: Path, receipt: dict[str, Any]) -> None:
    completed = set(receipt["completedTargets"])
    for record in records:
        identifier = submission_id(record)
        target = fingerprint(identifier)
        if target in completed:
            continue
        try:
            result = subprocess.run(
                ["asc", "--profile", profile, "testflight", "feedback", "delete", "--submission-id", identifier, "--confirm", "--output", "json"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd=REPOSITORY_ROOT,
                env=_command_environment(ASC_TELEMETRY_DISABLED="1"),
                timeout=120,
            )
        except FileNotFoundError as error:
            receipt["status"] = "partial"
            _write_private_json(receipt_path, receipt)
            raise RuntimeError("missing required command: asc") from error
        except subprocess.TimeoutExpired as error:
            receipt["status"] = "partial"
            _write_private_json(receipt_path, receipt)
            raise RuntimeError("App Store Connect deletion timed out; deletion is unconfirmed") from error
        if result.returncode != 0:
            receipt["status"] = "partial"
            _write_private_json(receipt_path, receipt)
            raise RuntimeError("App Store Connect deletion failed; deletion is unconfirmed")
        completed.add(target)
        receipt["completedTargets"] = sorted(completed)
        receipt["status"] = "deleting"
        _write_private_json(receipt_path, receipt)


def assert_delete_access(settings: dict[str, str], profile: str, records: list[dict[str, Any]]) -> None:
    for record in records:
        identifier = submission_id(record)
        response = asc_json(profile, ["testflight", "feedback", "view", "--submission-id", identifier, "--output", "json"])
        data = response.get("data")
        if not isinstance(data, dict) or data.get("id") != identifier:
            raise RuntimeError("delete profile cannot view a selected feedback record")
        attributes = data.get("attributes")
        returned_app = attributes.get("appId") if isinstance(attributes, dict) else data.get("appId")
        relationships = data.get("relationships")
        app_relationship = relationships.get("app") if isinstance(relationships, dict) else None
        app_data = app_relationship.get("data") if isinstance(app_relationship, dict) else None
        if returned_app is None and isinstance(app_data, dict):
            returned_app = app_data.get("id")
        if returned_app != settings["app_id"]:
            raise RuntimeError("delete profile record does not belong to the configured app")


def post_confirmation(settings: dict[str, str], pr_number: int) -> None:
    gh_json(settings, f"repos/{settings['github_repository']}/issues/{pr_number}/comments", method="POST", fields=[f"body={CONFIRMED_MARKER}\n\nDeletion confirmed after the pending archive comment and implementation checks."])


def archive(args: argparse.Namespace) -> int:
    settings = load_settings()
    pr_number, head = assert_reservation(settings, args.pr_number)
    if args.delete_profile != settings["delete_profile"]:
        raise ValueError("archive delete profile must match the configured delete_profile")
    if not PROFILE_PATTERN.fullmatch(args.delete_profile):
        raise ValueError("delete profile name contains unsupported characters")
    assert_handled_ledger_committed()
    validate_profile(args.delete_profile)
    allowed = load_allowed_email_fingerprints()
    records = [_feedback_input(Path(path), settings) for path in args.feedback]
    handled = load_handled()
    if not records:
        raise ValueError("archive requires at least one feedback record")
    if any(not is_eligible(record, allowed) or fingerprint(submission_id(record)) not in handled for record in records):
        raise ValueError("every selected feedback record must be eligible and handled")
    targets = ",".join(sorted(fingerprint(submission_id(record)) for record in records))
    token = hashlib.sha256(f"{head}\0{pr_number}\0{targets}".encode("utf-8")).hexdigest()
    marker = f"<!-- testflight-feedback-archive: pending head={head} targets={targets} nonce={token} -->"
    assert_github_write_access(settings)
    assert_delete_access(settings, args.delete_profile, records)
    assert_pending_comment(settings, pr_number, marker)
    receipt_path = archive_receipt_path(token)
    receipt = load_archive_receipt(receipt_path, head, pr_number, targets.split(","))
    if receipt.get("status") == "confirmed":
        raise ValueError("this archive is already confirmed")
    delete_feedback(args.delete_profile, records, receipt_path, receipt)
    if set(receipt["completedTargets"]) != set(targets.split(",")):
        raise RuntimeError("archive did not complete every selected deletion")
    try:
        post_confirmation(settings, pr_number)
    except (OSError, RuntimeError) as error:
        receipt["status"] = "deleted_pending_confirmation"
        _write_private_json(receipt_path, receipt)
        raise RuntimeError("deletion completed but confirmation comment failed; deletion remains unconfirmed") from error
    receipt["status"] = "confirmed"
    _write_private_json(receipt_path, receipt)
    print(json.dumps({"deletedCount": len(records), "deletionStatus": "confirmed"}, indent=2))
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = SafeArgumentParser(description="Safely fetch and explicitly archive private TestFlight feedback.")
    commands = parser.add_subparsers(dest="command", required=True)
    fetch_parser = commands.add_parser("fetch")
    fetch_parser.add_argument("--include-baseline", action="store_true")
    fetch_parser.add_argument("--include-handled", action="store_true")
    fetch_parser.add_argument("--no-screenshots", action="store_true")
    mark_parser = commands.add_parser("mark-handled")
    mark_parser.add_argument("--feedback", nargs="+", required=True)
    marker_parser = commands.add_parser("archive-marker")
    marker_parser.add_argument("--pr-number", type=int, required=True)
    marker_parser.add_argument("--feedback", nargs="+", required=True)
    archive_parser = commands.add_parser("archive")
    archive_parser.add_argument("--pr-number", type=int, required=True)
    archive_parser.add_argument("--delete-profile", required=True)
    archive_parser.add_argument("--feedback", nargs="+", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = make_parser().parse_args(argv)
        if args.command == "fetch":
            return fetch(args)
        if args.command == "mark-handled":
            return mark_handled(args)
        if args.command == "archive-marker":
            return archive_marker(args)
        if args.command == "archive":
            return archive(args)
        raise ValueError("unknown command")
    except (OSError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
