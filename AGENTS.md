# Agent release boundaries

Read `docs/PROJECT_BRIEF.md`, `docs/SECURITY_POLICY.md` and
`docs/RELEASE_DISTRIBUTION.md` before changing release or distribution files.

## Non-negotiable channel separation

- Google Play accepts only the signed `play` AAB. Never commit it, attach it to
  a GitHub Release, or upload it as a public workflow artifact.
- GitHub Releases and Obtainium accept only signed `full` release APKs. Never
  publish `play`, `qa`, `debug` or `profile` artifacts there.
- The `qa` flavor is internal emulator-test evidence and must never be public.
- Never commit or expose `key.properties`, keystores, passwords, tokens,
  mappings, diagnostic bundles, pairing payloads or private server details.
- Build outputs stay ignored. A request to build does not authorize upload,
  publication, tagging, repository visibility changes or Play submission.
- Every publication action requires explicit owner approval for that exact
  channel and artifact.

Use path-specific staging; never use `git add -A` or a broad recursive stage in
this repository.

## Cloud Agent toolchain

Flutter 3.47.1 (Dart 3.13.1), Java 17, and Android SDK 36 are already on the
machine. `flutter` and `dart` are on the default PATH. The Android SDK is
`/opt/android-sdk` (NDK 28.2.13676358) and the JDK is selected with
`flutter config`. This app is Android-only; there is no Linux or web target.

Use the checks in `CONTRIBUTING.md` and `docs/INSTALLATION.md`:

```bash
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test --concurrency=1
flutter build apk --debug --flavor full --dart-define=HERMES_FLAVOR=full
```

`uv` 0.12.7 is on PATH for `tool/e2e/run_local.sh`. That lane clones the pinned
Hermes checkout into a temp directory and does not touch `~/.hermes`.

## pr-quality locally

Docker, Gitleaks 8.28.0, and TruffleHog 3.97.0 are installed. `dockerd` uses
`fuse-overlayfs`. The environment start script launches it on boot and
`docker` then works without sudo. The pinned images from
`.github/workflows/pr-quality.yml` are already pulled. `reuse` 6.2.0 is on
PATH.

If `docker info` cannot connect, the boot script did not run. Start the
daemon, then retry the scan:

```bash
sudo sh -c 'setsid dockerd --host unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 < /dev/null &'
sudo chmod 666 /var/run/docker.sock
```

```bash
flutter gen-l10n
git diff --exit-code -- lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_es.dart
reuse lint
docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks@sha256:cdbb7c955abce02001a9f6c9f602fb195b7fadc1e812065883f695d1eeaba854 git /repo --no-banner --redact=100
docker run --rm -v "$PWD:/repo:ro" trufflesecurity/trufflehog@sha256:ff4c95e9df7d645daf2140e3ca1039031c63106268d5fbb25feb43ceca1bcc33 --no-update --fail --fail-on-scan-errors --exclude-detectors=URI --results=verified,unknown --json git file:///repo
echo "76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3  android/gradle/wrapper/gradle-wrapper.jar" | sha256sum -c -
./tool/sbom/generate.sh
git diff --exit-code -- sbom
python3 -m unittest discover -s test -p '*_test.py'
flutter analyze --fatal-infos
flutter test --concurrency=1
```

`gitleaks` and `trufflehog` on PATH are the same binaries as those images.
