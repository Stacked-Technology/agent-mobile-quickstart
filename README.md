# Mobile agent quickstart

This repository is a reusable, app-neutral starting point for letting coding agents work on mobile apps safely. It centralizes the operational pieces that are easy to forget:

- a private TestFlight feedback workflow with local-only artifacts;
- a generic Apple Silicon Sand/VM runner setup for GitHub Actions;
- an optional plain macOS self-hosted runner fallback;
- app, signing, App Store Connect, GitHub, and CI setup checklists; and
- a small agent playbook for recording durable, non-secret mobile knowledge.

It intentionally does not contain an app, credentials, tester identities, bundle IDs, organization settings, or production deployment policy. It references the maintained public Sand source as a pinned build dependency; copy the templates into an app repository and fill in the app-specific placeholders there.

## Start here

1. Read [docs/app-setup.md](docs/app-setup.md) and identify the app-specific values.
2. Read [docs/auth-and-secrets.md](docs/auth-and-secrets.md) before creating any local profile or GitHub secret.
3. Configure the isolated runner with [docs/sand-runner.md](docs/sand-runner.md).
4. Add the TestFlight skill from [.codex/skills/testflight-feedback/SKILL.md](.codex/skills/testflight-feedback/SKILL.md).
5. Copy the workflow templates from [templates/github/workflows](templates/github/workflows) into the app repository only after reviewing their `runs-on`, app path, branch guard, and release commands.

## Repository map

| Path | Purpose |
| --- | --- |
| `.codex/skills/testflight-feedback/` | Agent skill, deterministic helper, and local-only configuration examples |
| `scripts/update_sand.sh` | Fetch and build the pinned public Sand fork revision, with an override for another fork |
| `scripts/setup_sand_github_runner.sh` | Plan, validate, and explicitly apply the Sand/VM runner configuration |
| `scripts/setup_macos_actions_runner.sh` | Optional non-VM Apple Silicon runner bootstrap |
| `scripts/init_testflight_feedback.sh` | Create ignored local TestFlight configuration placeholders |
| `docs/` | Human setup and maintenance documentation |
| `templates/github/workflows/*.yml.example` | App-repository workflow templates; not active in this repository |

## Scope boundary

The setup scripts can configure local files, GitHub runner groups, and launch agents when an operator explicitly passes `--apply`. They do not create cloud resources, change production releases, or mint credentials. Review generated configuration before applying it, and keep all actual secrets in the operating system keychain, a dedicated secret manager, or GitHub's protected secret store.
