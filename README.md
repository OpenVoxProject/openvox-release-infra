# openvox-release-infra

Release pipeline for OpenVox packages. Downloads artifacts from S3, signs them (RPM, DEB, MSI, DMG), builds Apt/Yum repo metadata, and deploys to S3. Repo metadata lives in git for audit and rollback.

### Tasks

| Task | Purpose |
|------|---------|
| `bundle exec rake release` | Download, sign, and build repo metadata |
| `bundle exec rake deploy` | Push staged packages and metadata to S3 |
| `bundle exec rake verify` | Verify released packages are accessible in the deployed repos |
| `bundle exec rake rollback` | Restore repo state from a prior git commit |
| `bundle exec rake cleanup` | Remove orphaned packages from S3 |
| `bundle exec rake backup` | Sync S3 repos to GCS backup bucket |
| `bundle exec rake restore` | Restore S3 repos from GCS backup |
| `bundle exec rake restore:gcs` | Roll back GCS backup bucket to a point in time |
| `bundle exec rake reset_test` | Sync test buckets from production (with --delete) and clear local staging |
| `bundle exec rake reset` | Remove cached Docker container image |
| `bundle exec rake repo_packages:build` | Build and sign repo RPM/DEB packages and repo/list files |
| `bundle exec rake repo_packages:upload` | Upload repo package artifacts to S3 |
| `bundle exec rake repo_packages:add_platform` | Add a platform to a repo package definition |

## Release

Release a new version of a package to the repos.

**GitHub Actions:**

The Release GitHub action performs the following sequence of tasks: `backup` -> `release` -> `deploy` -> Push `state/` changes to the `main` branch only if `production` is checked -> `verify`

1. Go to Actions > "Release" workflow > Run workflow.
2. Fill in project, version, and optionally platform filters if you only want to release for certain platforms. This is a comma-separated list of platform names in the same format we use in vanagon (e.g. `el-9-x86_64,el-9-aarch64`).
3. Leave `production` unchecked. This deploys to the test repos.
4. The release action includes a step to run `bundle exec rake verify`, which checks the repos to ensure the new package is found in all of them.
5. If desired, verify the test repos look correct manually (install a package, check metadata).
6. Re-run the workflow with `production` checked. This deploys to production and commits `state/` to main, as well as runs `bundle exec rake verify` against the production repos to ensure the packages are present and valid.

**Local:**
Note that in order to release MacOS packages, you must run on a MacOS host with the appropriate secrets.

```bash
source ~/.openvox-release-secrets

# Deploy to test first
bundle exec rake backup
PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake release
bundle exec rake deploy
bundle exec rake verify

# After verifying test repos, then deploy to production
PRODUCTION=true bundle exec rake backup
PRODUCTION=true PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake release
PRODUCTION=true bundle exec rake deploy
PRODUCTION=true bundle exec rake verify
git push
```

## Rollback

Roll back the repo metadata to a previous release state. Note that the `bundle exec rake rollback` command only changes the `state/` directory to match what the `state/` directory looked like for the given commit. This does not roll back *all* files in the openvox-release-infra repo, nor does it push those changes to GitHub or deploy to the Apt/Yum repositories itself. Additionally, this task creates a new commit rather than reverting or resetting, so history is preserved.

Because the rake task only rolls back the metadata, orphaned packages may then exist in the Apt/Yum repositories. This is harmless, as package managers will simply refuse to see those packages, but cleaning them up is recommended via the `cleanup` rake task.

The Rollback GitHub action performs the following steps: `rollback` -> `deploy` -> Push `state/` changes to the `main` branch only if `production` is checked -> `cleanup`.

**GitHub Actions:**

1. Find the commit to roll back to: `git log --oneline state/`
2. Go to Actions > "Rollback" workflow > Run workflow.
3. Enter the commit SHA. Leave "cleanup" checked to remove orphaned packages.
4. Leave "production" unchecked to test the rollback first, then re-run with "production" checked.

**Local:**

```bash
git log --oneline state/
COMMIT=abc1234 bundle exec rake rollback
bundle exec rake deploy
git push
bundle exec rake cleanup
```

## Reset Test Repos

Sync the test repos from the current production repos. Use this to get a clean test environment that mirrors production.

```bash
bundle exec rake reset_test
```

This syncs packages and metadata from production to test using `--delete`, preserving repo setup packages and config files that are specific to the test repo. Local staging/ is cleared.

## Disaster Recovery

If the S3 repos are corrupted or accidentally deleted and using the above commands can not bring things back to a working state, restore from the GCS backup. This is a destructive operation that overwrites the current S3 repos with the backup contents. Additionally, if the repos got backed up to GCS in a broken state, you can roll back the GCS backup buckets to a point in time within the last 90 days.

**GitHub Actions:**

1. Go to Actions > "Disaster Recovery" workflow > Run workflow.
2. To test first, leave `production` blank and optionally check `Use the production GCS backup as source` to restore from the production backup into the test buckets. If a point-in-time recovery from the GCS backup is needed (the current backup is bad and you know there was a good backup within the last 90 days), enter a timestamp between the good and bad backups (RFC 3339 format with timezone, e.g. `2026-04-15T13:30:00-07:00`).
3. Manually verify the test repos look correct and function as expected with package managers.
4. Re-run the workflow, typing `I want to restore to production` in the `production` field.
6. After the workflow completes, if you've restored to a time prior to the current state of the `state/` directory in the openvox-release-infra repo, use the rollback task with the appropriate commit.

**Local:**

Simple restore (restore current GCS state to S3, omit GCS_SOURCE if you are testing restore from the `openvox-backup-test` bucket):

```bash
# 1. Test first
GCS_SOURCE=gs://openvox-backup TARGET=all bundle exec rake restore

# 2. Manually verify the test repo works and looks as expected.

# 3. Then production
PRODUCTION=true TARGET=all bundle exec rake restore

# 4. Roll back state so the GitHub repo state matches what is in the
# Apt/Yum repos if necessary.
git log --oneline state/
COMMIT=abc1234 bundle exec rake rollback
git push

# 5. Remove orphaned packages
PRODUCTION=true bundle exec rake cleanup
```

Point-in-time recovery (if a bad backup has overwritten the GCS state):

```bash
# 1. Roll back GCS to a timestamp between the good and bad backups
TIMESTAMP=2026-04-15T13:30:00-07:00 PRODUCTION=true bundle exec rake restore:gcs

# 2. Sync recovered GCS state to S3
PRODUCTION=true TARGET=all bundle exec rake restore

# 3. If necessary, roll back local state/ to the matching commit
git log --oneline state/
COMMIT=abc1234 bundle exec rake rollback
git push

# 4. Remove orphaned packages from S3
PRODUCTION=true bundle exec rake cleanup
```

Timestamps are RFC 3339 format with timezone offsets (e.g., `2026-04-15T13:30:00-07:00` or `2026-04-15T20:30:00Z`). The timestamp should be a point in time between the good and bad backups. The task recovers objects that existed at that time and were subsequently overwritten. This only works within the 90-day soft-delete retention window.

## Repo Packages

Build, sign, and upload the small noarch `openvox*-release` RPM/DEB packages that register the OpenVox Apt/Yum repos on end-user systems. These packages drop `.repo` files, `.list` files, GPG public keys, and Apt pin preferences into the correct locations.

**GitHub Actions:**

Go to Actions > "Repo Packages" workflow > Run workflow. Leave `production` unchecked to build packages pointing at the test repos and upload to the test buckets. Re-run with `production` checked for production.

Generally, you should not need to update the packages unless we fundamentally change something about all the packages, such as using a different public key or repository URL. The task/action will refuse to overwrite files that already exist unless you select `Overwrite exist artifacts in S3` in the action or set `FORCE_OVERWRITE` when running locally.

When adding a brand new platform for which we do not yet have an `openvox*-release` package, run the "Add New Repo Package Platform" GitHub action or the `repo_packages:add_platform` task. The `PLATFORM` string is a comma-separated list of platforms to add (e.g. `fedora-44`, `ubuntu26.04`). Architecture is irrelevant since these are noarch packages. Hyphens are optional (`el9` and `el-9` both work).

The GitHub action pushes the platform definition directly to main and optionally builds and uploads the packages for the new platforms. Check "Build and upload to test" and/or "Build and upload to production" to build immediately.

**Local:**

```bash
source ~/.openvox-release-secrets

# Build and upload all platforms to test
bundle exec rake repo_packages:build
bundle exec rake repo_packages:upload

# Build and upload only specific platforms
PLATFORM=fedora-44,sles-16 COMPONENT=openvox8 bundle exec rake repo_packages:build
PLATFORM=fedora-44,sles-16 COMPONENT=openvox8 bundle exec rake repo_packages:upload

# Build and upload to production
PRODUCTION=true bundle exec rake repo_packages:build
PRODUCTION=true bundle exec rake repo_packages:upload

# Force overwriting packages that already exist in the S3 bucket
PRODUCTION=true bundle exec rake repo_packages:build
PRODUCTION=true FORCE_OVERWRITE=true bundle exec rake repo_packages:upload
```

**Add a new platform:**

```bash
PLATFORM=el-11,debian14,sles-16 COMPONENT=openvox8 bundle exec rake repo_packages:add_platform
# Commits locally; push manually when ready.
# Then build and upload for just the new platforms:
PRODUCTION=true PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:build
PRODUCTION=true PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:upload
```

Platform definitions live in `files/repo_packages/*.json` with a file for each repo component (e.g. `openvox8`). The `add_platform` task infers the package kind (RPM or DEB) from the OS name, normalizes the format, sorts the platforms list, and commits the change.

| Variable | Purpose |
|----------|---------|
| `COMPONENT` | Repo component (e.g. `openvox7`, `openvox8`). Defaults to `openvox8`. |
| `PLATFORM` | Comma-separated platform(s) (e.g. `el-9`, `debian13`, `sles-15`) |
| `FORCE_OVERWRITE` | Set to `true` to overwrite existing S3 artifacts during upload |
---

## Reference

### Prerequisites

- Ruby 3.2+
- Docker
- `bundle install`

macOS signing additionally requires a macOS host with Xcode command line tools.

### How it works

`rake release` downloads packages from the artifacts bucket, signs them, builds repo metadata in `staging/`, and commits the updated metadata to `state/` in git. `rake deploy` uploads from `staging/` to S3 in two phases: packages first (invisible to clients until metadata points to them), then metadata. Do not modify `staging/` between release and deploy.

`state/` is the source of truth for what metadata is currently live in production. `git log state/` shows every change. Each release and rollback creates a signed commit.

### Environment variables

#### Required for `rake release`

| Variable | Purpose |
|----------|---------|
| `PROJECT` | Package name (e.g. `openvox-agent`, `openbolt`). Prompted interactively if unset. |
| `VERSION` | Package version (e.g. `8.28.0`). Prompted interactively if unset. |
| `GPG_PRIVATE_KEY_B64` | Base64-encoded GPG private key for signing |
| `AWS_ACCESS_KEY_ID` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key |

#### Optional

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPONENT` | `openvox8` | Repo component (e.g. `openvox7`, `openvox8`) |
| `PLATFORMS` | all | Comma-separated platform filter (e.g. `el-9-x86_64,debian-13-amd64`) |
| `PRODUCTION` | `false` | Deploy to production S3 buckets and commit state/ |
| `FORCE_OVERWRITE` | `false` | Allow overwriting existing packages in metadata |
| `ARTIFACTS_BUCKET` | `openvox-artifacts` | S3 bucket for build artifacts |
| `APT_BUCKET` | production: `s3://openvox-apt`, test: `s3://openvox-artifacts/repo_test/apt` | S3 Apt bucket |
| `YUM_BUCKET` | production: `s3://openvox-yum`, test: `s3://openvox-artifacts/repo_test/yum` | S3 Yum bucket |
| `DOWNLOADS_BUCKET` | production: `s3://openvox-artifacts/downloads`, test: `s3://openvox-artifacts/repo_test/downloads` | S3 downloads bucket |
| `GCS_BUCKET` | production: `gs://openvox-backup`, test: `gs://openvox-backup-test` | GCS backup bucket (contains apt/, yum/, downloads/) |

#### MSI signing (Windows)

| Variable | Purpose |
|----------|---------|
| `WINDOWS_SM_API_KEY` | DigiCert KeyLocker API key |
| `WINDOWS_SM_HOST` | DigiCert KeyLocker host |
| `WINDOWS_SM_CLIENT_CERT_B64` | Base64-encoded .p12 client certificate |
| `WINDOWS_SM_CLIENT_CERT_PASSWORD` | Client certificate password |
| `WINDOWS_CERT_ALIAS` | Certificate alias |

#### DMG signing (macOS)

| Variable | Purpose |
|----------|---------|
| `MACOS_APP_CERT_B64` | Base64-encoded Developer ID Application .p12 |
| `MACOS_INSTALLER_CERT_B64` | Base64-encoded Developer ID Installer .p12 |
| `MACOS_CERT_PASSWORD` | Password for the .p12 files |
| `MACOS_APP_SIGNING_IDENTITY` | Code signing identity name |
| `MACOS_INSTALLER_SIGNING_IDENTITY` | Installer signing identity name |
| `MACOS_NOTARY_APPLE_ID` | Apple ID email for notarization |
| `MACOS_NOTARY_TEAM_ID` | Apple Developer team ID |
| `MACOS_NOTARY_APP_TOKEN` | App-specific password for notarization |

#### Operations

| Variable | Purpose |
|----------|---------|
| `COMMIT` | Git SHA for `rake rollback` |
| `TARGET` | `apt`, `yum`, `downloads`, or `all` for `rake restore` |
| `CONFIRM_CLEANUP` | Set to `true` to skip interactive confirmation in `rake cleanup` |
| `CONFIRM_RESTORE` | Set to `true` to skip interactive confirmation in `rake restore` |

### Platform filter format

The `PLATFORMS` variable uses `<os>-<version>-<arch>` triples:

```
el-9-x86_64        -> matches .el9.x86_64.rpm
debian-13-amd64    -> matches +debian13_amd64.deb
ubuntu-24.04-arm64 -> matches +ubuntu24.04_arm64.deb
fedora-42-x86_64   -> matches .fc42.x86_64.rpm
macos-all-arm64    -> matches arm64 DMGs
windows-all-x64    -> matches all MSIs
```

Each entry must be a full triple. When set, only matching platforms are processed.

### Container

A single Docker image (Debian 13) is built on first run and cached. It includes: createrepo-c, rpm, debsigs, dpkg-dev, apt-utils, gnupg, jsign, osslsigncode, ruby, fpm, and jq.

The image contains no secrets. GPG keys are imported fresh each run. Run `bundle exec rake reset` to remove the cached image and force a rebuild.

### GCS backup

Backup and restore use `gcloud storage rsync` to sync between S3 (s3.osuosl.org) and GCS. The GCS buckets use soft delete so each backup preserves prior state for 90 days. See [docs/gcs-setup.md](docs/gcs-setup.md) for bucket creation, Workload Identity Federation, and cost estimation.

### Secrets

All env vars with a `_B64` suffix contain base64-encoded binary or multiline data. Everything else is plain text. See [docs/secrets.md](docs/secrets.md) for how to generate each secret, GitHub Actions configuration, and a local secrets file template.

When running locally, `PROJECT` and `VERSION` can be omitted and will be prompted interactively. `COMPONENT` defaults to `openvox8`.

## Bootstrap

The bootstrap tasks were used during the initial migration from the previous repo management tooling. See [docs/bootstrap.md](docs/bootstrap.md) for details. They are kept in the repo for historical reference.
