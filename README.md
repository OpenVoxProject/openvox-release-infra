# openvox-release-infra

Release pipeline for OpenVox packages. Downloads artifacts from S3, signs them (RPM, DEB, MSI, DMG), builds Apt/Yum repo metadata, and deploys to S3. Repo metadata lives in git for audit and rollback.

### Documentation

- [Reference](docs/reference.md): environment variables, platform filter format, tasks, container, architecture
- [Running locally](docs/running-locally.md): local equivalents of every GitHub Actions workflow
- [Secrets](docs/secrets.md): generating secrets, GitHub Actions configuration, local secrets file
- [GCS backup setup](docs/gcs-setup.md): bucket creation, Workload Identity Federation, cost estimation
- [Bootstrap](docs/bootstrap.md): initial migration from previous repo tooling (historical)

## Release a package

Example: release openvox-agent 8.26.0.

1. Go to Actions > **Reset Test Repos** > Run workflow. This syncs the test repos from production so you're testing against a clean baseline.
2. Go to Actions > **Release** > Run workflow.
   - Project: `openvox-agent`
   - Version: `8.26.0`
   - Leave `production` unchecked.
3. The workflow performs: `backup` -> `release` -> `deploy` -> `verify`. For the test run, no commit is created.
4. If desired, manually verify the test repos (install a package, check metadata).
5. Re-run the **Release** workflow with the same project and version, this time checking `production`. The workflow performs: `backup` -> `release` -> `deploy` -> push `state/` to main -> `verify`.

**Options:**

- **Component:** Defaults to `openvox8`. Set to `openvox9` (or other component) if releasing for a different repo component.
- **Platform filter:** Enter a comma-separated list of platforms in vanagon format (e.g. `el-9-x86_64,debian-13-amd64`) to release only specific platforms. Leave blank for all.
- **Force overwrite:** Check this to overwrite packages that already exist in the repos (e.g. when re-signing). Do not do this unless you really have to, because people's package managers will complain about the packages having a different hash.

**Note**

When doing the very first release of packages into a new component that doesn't yet exist in the repo (e.g. `openvox9`, `openvox8-nightlies`), this automation will work to create the relevant paths in the repo, but you should not make a noarch package (e.g. `openvox-server` or `openvoxdb`) the first released package. Because we fan out noarch packages into each architecture-specific location, you should release a package like `openvox-agent` first to populate all of these relevant architecture paths.

## Repo package management

The small noarch `openvox*-release` RPM/DEB packages register the OpenVox Apt/Yum repos on end-user systems. They drop `.repo` files, `.list` files, GPG public keys, and Apt pin preferences into the correct locations. Platform definitions live in `files/repo_packages/*.json`, with a file for each repo component (e.g. `openvox8`).

### Add a new platform

Example: add Fedora 44 and Ubuntu 26.04 to the openvox8 repos.

1. Go to Actions > **Add New Repo Package Platform** > Run workflow.
   - Component: `openvox8`
   - Platform(s): `fedora-44,ubuntu26.04`
   - Optionally check **Build and upload to test** and/or **Build and upload to production** to build immediately.
2. The workflow updates the platform definition in `files/repo_packages/openvox8.json` and pushes to main. If build options were checked, it builds and uploads the packages.

Architecture suffixes are ignored (these are noarch packages). Hyphens are optional (`el9` and `el-9` both work). The task infers the package kind (RPM or DEB) from the OS name, normalizes the format, sorts the platforms list, and commits the change.

### Rebuild repo packages

Rebuild and upload repo packages for all or specific platforms. Generally only needed when something fundamental changes (e.g. a new GPG key or repository URL).

1. Go to Actions > **Build Repo Packages** > Run workflow.
   - Leave `production` unchecked to build packages pointing at the test repos and upload to the test buckets.
   - Optionally enter specific platforms (e.g. `fedora-44,sles-16`). Leave blank for all.
2. Verify the test packages work as expected.
3. Re-run with `production` checked for production.

The workflow will refuse to overwrite packages that already exist in S3 unless **Overwrite existing artifacts in S3** is checked.

## Disaster recovery

### Rollback

Roll back the repo metadata to a previous release state. The workflow performs: `rollback` -> `deploy` -> push `state/` to main (only if `production` is checked) -> `cleanup`. This creates a new commit rather than reverting or resetting, so history is preserved.

1. Find the commit to roll back to: `git log --oneline state/`
2. Go to Actions > **Rollback** > Run workflow.
   - Enter the commit SHA.
   - Leave **cleanup** checked to remove orphaned packages.
   - Leave `production` unchecked to test first.
3. After verifying the test repos, re-run with `production` checked.

### Restore from backup

If the S3 repos are corrupted or accidentally deleted and a rollback can't fix it, restore from the GCS backup. This is a destructive operation that overwrites the current S3 repos with the backup contents.

1. Go to Actions > **Disaster Recovery (Restore from GCS)** > Run workflow.
2. Choose a **target** (`all`, `apt`, `yum`, or `downloads`). Defaults to `all`.
3. Leave `production` blank to restore to the test buckets first. Optionally check **Use the production GCS backup as source** to test with production backup data.
4. If the current GCS backup is also bad, enter a timestamp between the good and bad backups (RFC 3339 format with timezone, e.g. `2026-04-15T13:30:00-07:00`). This works within the 90-day soft-delete window.
5. Manually verify the test repos.
6. Re-run, typing `I want to restore to production` in the `production` field.
7. If the restored state is older than the current `state/` directory, follow up with a [rollback](#rollback) to the matching commit.
