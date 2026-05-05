# openvox-release-infra

Release pipeline for OpenVox packages. Downloads artifacts from S3, signs them (RPM, DEB, MSI, DMG), builds APT/YUM repo metadata, and deploys to S3. Repo metadata lives in git for audit and rollback.

## Release

Release a new version of a package to the repos.

**GitHub Actions:**

1. Go to Actions > "Release" workflow > Run workflow.
2. Fill in project, version, and optionally platform filters.
3. Leave "production" unchecked. This deploys to the test repos.
4. Verify the test repos look correct (install a package, check metadata).
5. Re-run the workflow with "production" checked. This deploys to production and commits state/ to main.

**Local:**

```bash
source ~/.openvox-release-secrets

# Deploy to test first
PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake backup
PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake release
bundle exec rake deploy

# Verify test repos, then deploy to production
PRODUCTION=true PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake backup
PRODUCTION=true PROJECT=openvox-agent VERSION=8.28.0 bundle exec rake release
PRODUCTION=true bundle exec rake deploy
git push
```

## Rollback

Roll back the repos to a previous release state.

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
bundle exec rake cleanup
git push
```

Rollback creates a new commit (not a force-push) so history is preserved. Cleanup removes packages from S3 that are no longer referenced by the current metadata.

## Bootstrap

Get the test repos in sync with the current production repos. Run this when setting up for the first time, or to reset test repos after they've drifted.

**GitHub Actions:**

Go to Actions > "Bootstrap Test Repos" workflow > Run workflow.

**Local:**

```bash
bundle exec rake bootstrap
```

This downloads production metadata, reformats it into state/, deploys it to the test buckets, and syncs all packages from production to test. Run `bootstrap:metadata` alone if you only need to refresh metadata without re-syncing all packages.

## One-Time Migration to Production

**WARNING: These commands are for the initial migration ONLY. Once production is being deployed to from this repo, they should never be used again. They will overwrite production repos with whatever is in the test repos.**

After running `bootstrap` and verifying the test repos are correct (install packages, check metadata, test with real package managers), sync the test repos to production with `--delete` to replace old-format metadata and clean up orphan files:

```bash
# Sync yum test -> production (excludes release packages, repo config files, index)
aws s3 sync --endpoint-url=https://s3.osuosl.org --delete \
  s3://openvox-artifacts/repo_test/yum/ s3://openvox-yum/ \
  --exclude 'openvox*-release-*' --exclude 'repo_files/*' --exclude 'index.html'

# Sync apt test -> production (excludes release packages, list config files, index)
aws s3 sync --endpoint-url=https://s3.osuosl.org --delete \
  s3://openvox-artifacts/repo_test/apt/ s3://openvox-apt/ \
  --exclude 'openvox*-release-*' --exclude 'list_files/*' --exclude 'index.html'
```

After this, production repos use the new metadata format and this repo manages all future changes via `rake release` and `rake deploy`.

## Disaster Recovery

If the S3 repos are corrupted or accidentally deleted, restore from the GCS backup. This is a destructive operation that overwrites the current S3 repos with the backup contents.

**Test the restore process first:**

1. Go to Actions > "Disaster Recovery" workflow > Run workflow.
2. Leave "production" unchecked.
3. Optionally enter a timestamp to restore GCS to a point in time (within the 90-day soft-delete window).
4. Set target to "all" or a specific repo (apt, yum, downloads).
5. Verify the test repos are correct.

**Restore production:**

1. Re-run the workflow with "production" checked and the same timestamp.
2. The workflow uses a protected GitHub environment requiring approval before it runs.

**Local:**

```bash
# Optionally restore GCS bucket to a point in time first
gcloud storage restore "gs://openvox-backup/**" --async \
    --allow-overwrite \
    --created-before-time="2026-04-15T00:00:00Z" \
    --deleted-after-time="2026-04-15T00:00:00Z"
# Wait for the async operation to complete (check: gcloud storage operations list)

# Then restore from GCS to S3
PRODUCTION=true TARGET=all bundle exec rake restore
```

Timestamps are RFC 3339 format. You can use timezone offsets (e.g., `2026-04-15T00:00:00-07:00` for Pacific time). This only works within the 90-day soft-delete retention window.

## Release Packages

Build, sign, and upload the small noarch RPM/DEB packages that register the OpenVox yum/apt repos on end-user systems (like `puppetlabs-release` packages). These packages drop `.repo` files, `.list` files, GPG public keys, and APT pin preferences into the correct locations.

**GitHub Actions:**

Go to Actions > "Release Packages" workflow > Run workflow. Leave "production" unchecked to build packages pointing at the test repos and upload to the test buckets. Re-run with "production" checked for production.

**Local:**

```bash
source ~/.openvox-release-secrets

# Build, sign, and upload to test
bundle exec rake release_packages:build
bundle exec rake release_packages:upload

# Build, sign, and upload to production
PRODUCTION=true bundle exec rake release_packages:build
PRODUCTION=true bundle exec rake release_packages:upload
```

**Add a new platform:**

```bash
bundle exec rake release_packages:add_platform \
    COMPONENT=openvox8 PLATFORM=el-11,debian14,sles-16
# Commits locally; push manually when ready
```

Platform definitions live in `files/release_packages/openvox7.json` and `openvox8.json`. The `add_platform` task infers the package kind (rpm or deb) from the OS name, normalizes the format, and commits the change. Arch suffixes (e.g. `-x86_64`, `-amd64`) are stripped automatically. SLES is treated as an RPM variant (the only difference is the repo file installs to `etc/zypp/repos.d` instead of `etc/yum.repos.d`).

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

### Tasks

| Task | Purpose |
|------|---------|
| `rake release` | Download, sign, and build repo metadata |
| `rake deploy` | Push staged packages and metadata to S3 |
| `rake rollback` | Restore repo state from a prior git commit |
| `rake cleanup` | Remove orphaned packages from S3 |
| `rake backup` | Sync S3 repos to GCS backup bucket |
| `rake restore` | Restore S3 repos from GCS backup |
| `rake bootstrap` | Run both bootstrap steps below |
| `rake bootstrap:metadata` | Reformat production metadata into state/ and deploy to test buckets |
| `rake bootstrap:packages` | Copy packages from production to test S3 buckets |
| `rake reset` | Remove cached Docker container image |
| `rake release_packages:build` | Build and sign release RPM/DEB packages and repo/list files |
| `rake release_packages:upload` | Upload release package artifacts to S3 |
| `rake release_packages:add_platform` | Add a platform to a release package definition |

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
| `APT_BUCKET` | production: `s3://openvox-apt`, test: `s3://openvox-artifacts/repo_test/apt` | S3 APT bucket |
| `YUM_BUCKET` | production: `s3://openvox-yum`, test: `s3://openvox-artifacts/repo_test/yum` | S3 YUM bucket |
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

The image contains no secrets. GPG keys are imported fresh each run. Run `rake reset` to remove the cached image and force a rebuild.

### GCS backup

Backup and restore use `gcloud storage rsync` to sync between S3 (s3.osuosl.org) and GCS. The GCS buckets use soft delete so each backup preserves prior state for 90 days. See [docs/gcs-setup.md](docs/gcs-setup.md) for bucket creation, Workload Identity Federation, and cost estimation.

### Secrets

All env vars with a `_B64` suffix contain base64-encoded binary or multiline data. Everything else is plain text. See [docs/secrets.md](docs/secrets.md) for how to generate each secret, GitHub Actions configuration, and a local secrets file template.

When running locally, `PROJECT` and `VERSION` can be omitted and will be prompted interactively. `COMPONENT` defaults to `openvox8`.
