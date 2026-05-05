# Bootstrap (Historical)

The bootstrap tasks were used during the initial migration from the previous repo management tooling. They download production metadata, reformat it into the new metadata format (simple filenames, no database), store it in state/, and sync everything to the test repos. They are kept in the repo for historical reference and in case similar reformatting is needed in the future.

```bash
bundle exec rake bootstrap:metadata    # Reformat production metadata into state/ and deploy to test
bundle exec rake bootstrap:packages    # Copy packages from production to test S3 buckets
bundle exec rake bootstrap             # Run both steps above
```

## Migration to production

After bootstrapping and verifying the test repos are correct (install packages, check metadata, test with real package managers), the test repos were synced to production with `--delete` to replace the old metadata format:

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

After this, production repos use the new metadata format and this repo manages all future changes via `bundle exec rake release` and `bundle exec rake deploy`.
