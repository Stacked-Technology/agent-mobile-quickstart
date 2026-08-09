# Mobile app setup

Use this checklist when adding the quickstart to an existing iOS/Android app or when starting a new one. The quickstart is app-agnostic: replace every placeholder with values for the app being automated.

## 1. Establish the app contract

Record these values in the app repository's private setup notes or GitHub variables, not in this public template:

| Value | Example shape | Where it is used |
| --- | --- | --- |
| Mobile app directory | `apps/mobile` or `.` | CI working directory |
| Package manager | `npm`, Yarn Classic/Berry, or `pnpm` | Dependency installation |
| Package-manager version/lockfile | e.g. Yarn 1 + `yarn.lock` or Yarn 4 + `yarn.lock` | Exact install flags in CI |
| Node version | `20` or the version in `.nvmrc` | CI and local development |
| iOS bundle identifier | `com.example.app` | Apple Developer and App Store Connect |
| Android application ID | `com.example.app` | Google Play and Android builds |
| iOS scheme/workspace | app-specific | Simulator and archive commands |
| Release command | Fastlane, EAS, Xcode, or Gradle | TestFlight workflow |
| Test command | app-specific | PR validation |

Keep these values in one app-owned configuration document. Agents should not guess a bundle ID, scheme, release lane, or environment name from a nearby project.

## 2. Local development prerequisites

Install only the tools required by the app:

- macOS on Apple Silicon for iOS builds;
- the supported Node.js version and the selected package manager;
- Xcode, command-line tools, simulator runtimes, and a signed-in developer account for iOS;
- Android Studio, SDK/platform tools, and an emulator or device when Android work is in scope;
- Ruby/Bundler and Fastlane only when the app uses Fastlane;
- the app's framework CLI, such as Expo, only when the app uses it;
- `gh` for GitHub operations; and
- `asc` (or the team's approved App Store Connect CLI) for TestFlight feedback and release operations.

Verify the toolchain before touching app code:

```bash
xcodebuild -version
xcrun simctl list devices available
node --version
gh auth status
```

Do not put API keys, provisioning profiles, or `.env` files in the repository. A local developer can use keychain-backed profiles or a secret manager instead.

## 3. Configure the app

Complete the app's normal setup before enabling agent workflows:

1. Install dependencies from the lockfile.
2. Generate native projects only through the app's documented command.
3. Configure development and test environment variables from an ignored `.env` file or the framework's supported secret store.
4. Confirm the app launches in an iOS simulator and an Android emulator, if Android is supported.
5. Confirm a release build can be produced locally by a human operator.
6. Add deterministic `lint`, `test`, and, where practical, simulator smoke commands to the app's package scripts.

The workflow templates assume these commands exist only after you adapt them. A template is not evidence that an app is release-ready.

## 4. Apple setup

Create or verify, in order:

1. The Apple Developer App ID matching the iOS bundle identifier.
2. Development and distribution certificates owned by the team account.
3. Development, ad hoc, or App Store provisioning profiles as required by the release path.
4. The App Store Connect app record with the same bundle identifier.
5. Test information, export compliance answers, privacy details, and tester groups.
6. A least-privilege App Store Connect API key/profile for read-only feedback access.
7. A separately named write-capable profile only for an explicitly approved archive/delete operation.

The read-only and write-capable profiles must not be interchangeable. Keep the private key out of Git and out of the runner image when a supported keychain or secret manager integration is available.

## 5. GitHub setup

Configure the repository before enabling release workflows:

- protect the default branch and require review for release changes;
- set repository variables for non-secret app settings and runner enablement;
- set protected environment approvals for TestFlight or production release jobs;
- install the GitHub App used by Sand with only the permissions described in [sand-runner.md](sand-runner.md);
- use the organization-wide private-only runner group by default, or restrict the runner group to the intended repository and workflow paths when selected scope is chosen; and
- keep the workflow templates disabled until the runner has passed its read-only validation.

## 6. First-run validation

Run the following in the app repository after adapting the templates. Use the command pair for the package manager recorded in the app contract:

```bash
# npm:  npm ci && npm test
# Yarn Berry:  yarn install --immutable && yarn test
# Yarn Classic: yarn install --frozen-lockfile && yarn test
# pnpm: pnpm install --frozen-lockfile && pnpm test
# Read-only runner checks.
bash scripts/setup_sand_github_runner.sh plan
bash scripts/update_sand.sh plan
```

Run `npx expo-doctor` only when the app uses Expo. The package-manager commands may install dependencies or execute lifecycle code; the two Sand `plan` commands are the read-only checks.

After a human reviews and applies the pinned Sand build, run `bash scripts/setup_sand_github_runner.sh validate` to verify its provenance, generated configuration, and launch-agent plist.

Then perform one manual simulator smoke test, one manual device/signing smoke test, and one dry-run or test-environment workflow run. Do not enable a production release merely because CI is green.
