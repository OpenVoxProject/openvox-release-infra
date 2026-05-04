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

### GCS backup setup

Backup and restore use `gcloud storage rsync` to sync between S3 (s3.osuosl.org) and GCS. The GCS buckets use soft delete so each backup preserves prior state for 90 days.

We use single-region Standard storage (`us-west1`, same region as OSU OSL) to keep things simple: no retrieval fees, no minimum storage duration rules, no inter-region replication costs. The purpose of this backup is protection against admin error, not infrastructure failure. At ~$4/month for 100 GiB across both buckets, the cost is negligible. In the future once the pipeline is stable, we could move to Coldline storage (~$0.80/month with a $2 one-time retrieval fee).

#### Creating the buckets

```bash
gcloud auth login
gcloud config set project openvox
```

You may see a warning about Application Default Credentials quota project. This can be safely ignored.

```bash
for bucket in openvox-backup openvox-backup-test; do
  gcloud storage buckets create "gs://${bucket}" --location=us-west1
  gcloud storage buckets update "gs://${bucket}" --versioning
  gcloud storage buckets update "gs://${bucket}" --soft-delete-duration=90d
done
```

#### Workload Identity Federation (GitHub Actions auth)

```bash
# Create a Workload Identity Pool
gcloud iam workload-identity-pools create github-actions \
    --location=global \
    --display-name="GitHub Actions"

# Create an OIDC provider for GitHub.
# Both orgs are listed because this was developed in overlookinfra first.
# Once we're using it for real, only the openvoxproject one is needed.
gcloud iam workload-identity-pools providers create-oidc github \
    --location=global \
    --workload-identity-pool=github-actions \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == 'openvoxproject/openvox-release-infra' || assertion.repository == 'overlookinfra/openvox-release-infra'"

# Create a service account for backup operations
gcloud iam service-accounts create openvox-backup \
    --display-name="OpenVox Repo Backup Service Account"

# Grant the service account access to the backup buckets
for bucket in openvox-backup openvox-backup-test; do
  gsutil iam ch \
      serviceAccount:openvox-backup@openvox.iam.gserviceaccount.com:objectAdmin \
      "gs://${bucket}"
done

# Allow the GitHub repos to impersonate the service account.
# Both orgs are listed because this was developed in overlookinfra first.
# Once we're using it for real, only the openvoxproject one is needed.
for repo in openvoxproject/openvox-release-infra overlookinfra/openvox-release-infra; do
  gcloud iam service-accounts add-iam-policy-binding \
      openvox-backup@openvox.iam.gserviceaccount.com \
      --role=roles/iam.workloadIdentityUser \
      --member="principalSet://iam.googleapis.com/projects/353991846409/locations/global/workloadIdentityPools/github-actions/attribute.repository/${repo}"
done
```

Our project number is `353991846409` (find with `gcloud projects describe openvox --format='value(projectNumber)'`).

#### Cost estimation

To estimate costs, check the current size of the production repos:

```bash
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-yum/ | tail -2
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-apt/ | tail -2
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-artifacts/downloads/ | tail -2
```

Multiply the total by 2 (production + test buckets). Operations and network are negligible for backup workloads.

Soft-delete retains deleted/overwritten objects for 90 days at the same storage rate. In practice, this adds minimal overhead: packages are written once and never overwritten (new versions have different filenames), so soft-delete only costs extra if you delete packages (e.g., after a rollback + cleanup). Metadata is overwritten on every release but is tiny (KBs) compared to packages (GBs).

See https://cloud.google.com/storage/pricing for current rates per GiB/month.

### Secrets

All env vars with a `_B64` suffix contain base64-encoded binary or multiline data. Everything else is plain text.

#### Generating secrets

**GPG key (RPM + DEB signing):**

```bash
gpg --export-secret-keys --armor openvox@voxpupuli.org | base64 -w0
```

**AWS credentials (S3 at s3.osuosl.org):**

From your OSU OSL account. No encoding needed.

**GCS (backup/restore):**

No secrets needed. Locally, authenticate with `gcloud auth login`. In CI, Workload Identity Federation handles auth automatically (see above).

**MSI signing (DigiCert ONE / KeyLocker):**

1. `WINDOWS_SM_API_KEY`: Create an API token in DigiCert ONE > API Tokens.
2. `WINDOWS_SM_HOST`: Your DigiCert ONE auth endpoint (e.g., `https://clientauth.one.digicert.com`).
3. `WINDOWS_SM_CLIENT_CERT_B64`: `base64 -w0 < client_cert.p12`
4. `WINDOWS_SM_CLIENT_CERT_PASSWORD`: The password set when the .p12 was created.
5. `WINDOWS_CERT_ALIAS`: The key pair alias from DigiCert ONE > Certificates.

**macOS signing:**

The pipeline creates a temporary keychain at runtime, imports certificates, and stores notary credentials:

```bash
# Export Developer ID Application and Installer certificates from Keychain Access as .p12 files
base64 -w0 < developer_id_application.p12   # -> MACOS_APP_CERT_B64
base64 -w0 < developer_id_installer.p12     # -> MACOS_INSTALLER_CERT_B64

# MACOS_CERT_PASSWORD = password set when exporting the .p12 files
# MACOS_APP_SIGNING_IDENTITY = identity name (e.g., "Developer ID Application: Vox Pupuli (XXXXXXXXXX)")
# MACOS_INSTALLER_SIGNING_IDENTITY = installer identity name
# MACOS_NOTARY_APPLE_ID = Apple ID email
# MACOS_NOTARY_TEAM_ID = team ID from Apple Developer portal
# MACOS_NOTARY_APP_TOKEN = app-specific password from appleid.apple.com
```

#### GitHub Actions secrets

Add these in Settings > Secrets and variables > Actions:

| Secret | Required for | How to generate |
|--------|-------------|-----------------|
| `GPG_PRIVATE_KEY_B64` | All signing | `gpg --export-secret-keys --armor openvox@voxpupuli.org \| base64 -w0` |
| `AWS_ACCESS_KEY_ID` | S3 operations | From OSU OSL S3 credentials |
| `AWS_SECRET_ACCESS_KEY` | S3 operations | From OSU OSL S3 credentials |
| `MACOS_APP_CERT_B64` | DMG signing | `base64 -w0 < developer_id_application.p12` |
| `MACOS_INSTALLER_CERT_B64` | DMG signing | `base64 -w0 < developer_id_installer.p12` |
| `MACOS_CERT_PASSWORD` | DMG signing | Password set when exporting .p12 files |
| `MACOS_APP_SIGNING_IDENTITY` | DMG signing | Identity name from the cert |
| `MACOS_INSTALLER_SIGNING_IDENTITY` | DMG signing | Identity name from the cert |
| `MACOS_NOTARY_APPLE_ID` | DMG signing | Apple ID email |
| `MACOS_NOTARY_TEAM_ID` | DMG signing | Team ID from Apple Developer portal |
| `MACOS_NOTARY_APP_TOKEN` | DMG signing | App-specific password from appleid.apple.com |
| `WINDOWS_SM_API_KEY` | MSI signing | DigiCert ONE > API tokens |
| `WINDOWS_SM_HOST` | MSI signing | DigiCert ONE account host URL |
| `WINDOWS_SM_CLIENT_CERT_B64` | MSI signing | `base64 -w0 < client_cert.p12` |
| `WINDOWS_SM_CLIENT_CERT_PASSWORD` | MSI signing | Set when creating the .p12 in DigiCert |
| `WINDOWS_CERT_ALIAS` | MSI signing | Certificate alias from DigiCert ONE |

MSI and macOS secrets are only needed if signing those package types. If omitted, signing is skipped.

#### Local secrets file

Create `~/.openvox-release-secrets` (not checked in):

```bash
export GPG_PRIVATE_KEY_B64="$(gpg --export-secret-keys --armor openvox@voxpupuli.org | base64 -w0)"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

# Only needed for MSI signing:
export WINDOWS_SM_API_KEY="your-digicert-api-key"
export WINDOWS_SM_HOST="https://clientauth.one.digicert.com"
export WINDOWS_SM_CLIENT_CERT_B64="$(base64 -w0 < /path/to/client_cert.p12)"
export WINDOWS_SM_CLIENT_CERT_PASSWORD="your-cert-password"
export WINDOWS_CERT_ALIAS="your-cert-alias"

# Only needed for DMG signing (macOS only):
export MACOS_APP_CERT_B64="$(base64 -w0 < /path/to/developer_id_application.p12)"
export MACOS_INSTALLER_CERT_B64="$(base64 -w0 < /path/to/developer_id_installer.p12)"
export MACOS_CERT_PASSWORD="your-p12-password"
export MACOS_APP_SIGNING_IDENTITY="Developer ID Application: Your Org (XXXXXXXXXX)"
export MACOS_INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Your Org (XXXXXXXXXX)"
export MACOS_NOTARY_APPLE_ID="your@email.com"
export MACOS_NOTARY_TEAM_ID="XXXXXXXXXX"
export MACOS_NOTARY_APP_TOKEN="your-app-specific-password"
```

Source it before running: `source ~/.openvox-release-secrets`

On a laptop, `PROJECT` and `VERSION` can be omitted and will be prompted interactively. `COMPONENT` defaults to `openvox8`.
