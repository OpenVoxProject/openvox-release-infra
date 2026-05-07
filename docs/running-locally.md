# Running Locally

All tasks can be run locally instead of through GitHub Actions. Source your secrets file before running:

```bash
source ~/.openvox-release-secrets
```

See [secrets.md](secrets.md) for how to set up this file.

For tasks that touch GCS (`backup`, `restore`, `restore:gcs`), authenticate with `gcloud auth login` first.

macOS package signing requires running on a macOS host with the appropriate secrets and Xcode command line tools.

## Release

```bash
# 1. Reset test repos to match production
bundle exec rake reset_test

# 2. Release to test
bundle exec rake backup
PROJECT=openvox-agent VERSION=8.26.0 bundle exec rake release
bundle exec rake deploy
PROJECT=openvox-agent VERSION=8.26.0 bundle exec rake verify

# 3. Manually verify test repos if desired

# 4. Release to production
PRODUCTION=true bundle exec rake backup
PRODUCTION=true PROJECT=openvox-agent VERSION=8.26.0 bundle exec rake release
PRODUCTION=true bundle exec rake deploy
PRODUCTION=true PROJECT=openvox-agent VERSION=8.26.0 bundle exec rake verify
git push
```

To release only specific platforms, add a `PLATFORMS` filter (comma-separated `<os>-<version>-<arch>` triples, see [reference.md](reference.md#platform-filter-format)):

```bash
PROJECT=openvox-agent VERSION=8.26.0 PLATFORMS=el-9-x86_64,el-9-aarch64 bundle exec rake release
```

## Rollback

```bash
# Find the commit to roll back to
git log --oneline state/

# Roll back state/ (this commits locally but does not push or deploy)
COMMIT=abc1234 bundle exec rake rollback

# Deploy to test first
bundle exec rake deploy
bundle exec rake cleanup

# After verifying test repos, deploy to production
PRODUCTION=true bundle exec rake deploy
git push
PRODUCTION=true bundle exec rake cleanup
```

## Repo packages

Build and upload:

```bash
# All platforms to test
bundle exec rake repo_packages:build
bundle exec rake repo_packages:upload

# Specific platforms only
PLATFORM=fedora-44,sles-16 bundle exec rake repo_packages:build
PLATFORM=fedora-44,sles-16 bundle exec rake repo_packages:upload

# Production
PRODUCTION=true bundle exec rake repo_packages:build
PRODUCTION=true bundle exec rake repo_packages:upload

# Force overwrite existing packages
PRODUCTION=true bundle exec rake repo_packages:build
PRODUCTION=true FORCE_OVERWRITE=true bundle exec rake repo_packages:upload
```

Add a new platform:

```bash
PLATFORM=el-11,debian14,sles-16 COMPONENT=openvox8 bundle exec rake repo_packages:add_platform
# Commits locally; push manually when ready.

# Build and upload to test first
PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:build
PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:upload

# After verifying, build and upload to production
PRODUCTION=true PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:build
PRODUCTION=true PLATFORM=el-11,debian14,sles-16 bundle exec rake repo_packages:upload
```

## Disaster recovery

Simple restore (restore current GCS state to S3). This example restores from the production GCS backup into the test S3 buckets. Omit `GCS_SOURCE` to use the test backup bucket instead.

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
# 1. Roll back the production GCS backup to a known-good timestamp
TIMESTAMP=2026-04-15T13:30:00-07:00 PRODUCTION=true bundle exec rake restore:gcs

# 2. Sync recovered GCS state to test S3 and verify
GCS_SOURCE=gs://openvox-backup TARGET=all bundle exec rake restore

# 3. Manually verify the test repos

# 4. Sync recovered GCS state to production S3
PRODUCTION=true TARGET=all bundle exec rake restore

# 5. If necessary, roll back local state/ to the matching commit
git log --oneline state/
COMMIT=abc1234 bundle exec rake rollback
git push

# 6. Remove orphaned packages from S3
PRODUCTION=true bundle exec rake cleanup
```

Timestamps are RFC 3339 format with timezone offsets (e.g., `2026-04-15T13:30:00-07:00` or `2026-04-15T20:30:00Z`). The timestamp should be a point in time between the good and bad backups. This only works within the 90-day soft-delete retention window.

## Reset test repos

```bash
bundle exec rake reset_test
```

Syncs packages and metadata from production to test using `--delete`. Repo setup packages and config files in the apt and yum test buckets are preserved; the downloads bucket is synced without excludes. Local `staging/` is cleared.
