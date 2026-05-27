# Reference

## Prerequisites

- Ruby 3.2+
- Docker
- `bundle install`

macOS signing additionally requires a macOS host with Xcode command line tools.

## Tasks

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
| `bundle exec rake reset` | Remove cached container, image, and Docker build cache |
| `bundle exec rake repo_packages:build` | Build and sign repo RPM/DEB packages and repo/list files |
| `bundle exec rake repo_packages:upload` | Upload repo package artifacts to S3 |
| `bundle exec rake repo_packages:add_platform` | Add a platform to a repo package definition |

## How it works

`rake release` downloads packages from the artifacts bucket, signs them, builds repo metadata in `staging/`, and commits the updated metadata to `state/` in git. `rake deploy` uploads from `staging/` to S3 in two phases: packages first (invisible to clients until metadata points to them), then metadata. Do not modify `staging/` between release and deploy.

`state/` is the source of truth for what metadata is currently live in production. `git log state/` shows every change. Each release and rollback creates a signed commit.

`rake rollback` only changes the `state/` directory to match what it looked like at the given commit. It does not roll back other files in the repo, push to GitHub, or deploy to S3. Those are separate steps. Because rollback only changes metadata, orphaned packages may exist in the repos afterward. This is harmless (package managers won't see them since the metadata no longer references them), but cleaning them up with `rake cleanup` is recommended.

## Apt codename aliases

Each apt dist is published under both the openvoxproject form (e.g. `debian13`, `ubuntu24.04`) and the upstream Debian/Ubuntu codename (e.g. `trixie`, `noble`). Both point at the same packages — only the per-dist metadata under `dists/<name>/` is duplicated; the `pool/` tree is shared.

Users can pick either form in their `sources.list`:

```
deb [...] https://apt.voxpupuli.org debian13 openvox8
deb [...] https://apt.voxpupuli.org trixie    openvox8
```

The shipped `openvox-release` packages continue to configure the canonical (openvoxproject) form by default. The codename alias is for users who manually pick it.

### How the codename is resolved

The canonical-to-codename mapping comes from Debian's upstream [distro-info-data](https://salsa.debian.org/debian/distro-info-data) — the same data that ships in `/usr/share/distro-info/{debian,ubuntu}.csv` on every Debian and Ubuntu host. The CSVs are fetched on demand by `Platform.codename_for` in [rakelib/lib/utils/platform.rb](../rakelib/lib/utils/platform.rb) the first time a release/rebuild needs them, and cached for the duration of that rake invocation.

This means `rake release` and `rake rebuild_apt_indexes` require network access to `salsa.debian.org`. If the fetch fails, the canonical metadata is still written; only the codename alias is skipped, with a warning.

If a new dist is added whose codename isn't in the upstream CSV yet, the codename alias is also skipped with a warning. The release otherwise proceeds normally.

## Environment variables

### Required for `rake release`

| Variable | Purpose |
|----------|---------|
| `PROJECT` | Package name (e.g. `openvox-agent`, `openbolt`). Prompted interactively if unset. |
| `VERSION` | Package version (e.g. `8.28.0`). Prompted interactively if unset. |
| `GPG_PRIVATE_KEY_B64` | Base64-encoded GPG private key for signing |
| `AWS_ACCESS_KEY_ID` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key |

`rake verify` requires `PROJECT`, `VERSION`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` (no GPG key needed; it uses the committed public key).

### Optional

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

### MSI signing (Windows)

| Variable | Purpose |
|----------|---------|
| `WINDOWS_SM_API_KEY` | DigiCert KeyLocker API key |
| `WINDOWS_SM_HOST` | DigiCert KeyLocker host |
| `WINDOWS_SM_CLIENT_CERT_B64` | Base64-encoded .p12 client certificate |
| `WINDOWS_SM_CLIENT_CERT_PASSWORD` | Client certificate password |
| `WINDOWS_CERT_ALIAS` | Certificate alias |

### DMG signing (macOS)

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

### Repo package tasks (`repo_packages:*`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMPONENT` | `openvox8` | Repo component for `add_platform` only (e.g. `openvox7`, `openvox8`). Not used by `build` or `upload`. |
| `PLATFORM` | all | Comma-separated platforms (e.g. `el-9,debian13,sles-15`). No arch suffix needed. Required for `add_platform`. |
| `FORCE_OVERWRITE` | `false` | Allow overwriting existing artifacts in S3 during upload |

### Operations

| Variable | Purpose |
|----------|---------|
| `COMMIT` | Git SHA for `rake rollback` |
| `TARGET` | `apt`, `yum`, `downloads`, or `all` for `rake restore` |
| `GCS_SOURCE` | GCS bucket URI for `rake restore` (read source) and `rake restore:gcs` (bucket to destructively roll back). Defaults to `PRODUCTION`-appropriate bucket. |
| `TIMESTAMP` | RFC 3339 timestamp for `rake restore:gcs` point-in-time recovery |
| `CONFIRM_CLEANUP` | Set to `true` to skip interactive confirmation in `rake cleanup` |
| `CONFIRM_RESTORE` | Set to `true` to skip interactive confirmation in `rake restore` |
| `CONFIRM_RESET` | Set to `true` to skip interactive confirmation in `rake reset_test` |

## Platform filter format

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

## Container

A single Docker image (Debian 13) is built on first run and cached. It includes: createrepo-c, rpm, debsigs, dpkg-dev, apt-utils, gnupg, jsign, osslsigncode, ruby, fpm, and jq.

The image contains no secrets. GPG keys are imported fresh each run. Run `bundle exec rake reset` to remove the cached image and force a rebuild.

## GCS backup

Backup and restore use `gcloud storage rsync` to sync between S3 (s3.osuosl.org) and GCS. The GCS buckets use soft delete so each backup preserves prior state for 90 days. See [gcs-setup.md](gcs-setup.md) for bucket creation, Workload Identity Federation, and cost estimation.

Point-in-time recovery works by restoring soft-deleted objects: `rake restore:gcs` finds objects that existed at the given timestamp and were subsequently overwritten or deleted, then restores them. The timestamp should fall between the last known-good backup and the bad one. Timestamps are RFC 3339 format with timezone offsets (e.g. `2026-04-15T13:30:00-07:00` or `2026-04-15T20:30:00Z`). This only works within the 90-day soft-delete retention window.

## Secrets

All env vars with a `_B64` suffix contain base64-encoded binary or multiline data. Everything else is plain text. See [secrets.md](secrets.md) for how to generate each secret, GitHub Actions configuration, and a local secrets file template.

When running locally, `PROJECT` and `VERSION` can be omitted and will be prompted interactively. `COMPONENT` defaults to `openvox8`.

## Bootstrap

The bootstrap tasks were used during the initial migration from the previous repo management tooling. See [bootstrap.md](bootstrap.md) for details. They are kept in the repo for historical reference.
