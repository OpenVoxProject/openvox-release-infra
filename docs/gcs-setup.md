# GCS Backup Setup

Backup and restore use `gcloud storage rsync` to sync between S3 (s3.osuosl.org) and GCS. The GCS buckets use soft delete so each backup preserves prior state for 90 days.

We use single-region Standard storage (`us-west1`, same region as OSU OSL) to keep things simple: no retrieval fees, no minimum storage duration rules, no inter-region replication costs. The purpose of this backup is protection against admin error, not infrastructure failure. At ~$4/month for 100 GiB across both buckets, the cost is negligible. In the future once the pipeline is stable, we could move to Coldline storage (~$0.80/month with a $2 one-time retrieval fee).

These buckets are currently located in Overlook InfraTech's GCP space.

## Creating the buckets

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

## Workload Identity Federation (GitHub Actions auth)

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

## Cost estimation

To estimate costs, check the current size of the production repos:

```bash
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-yum/ | tail -2
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-apt/ | tail -2
aws s3 ls --endpoint-url=https://s3.osuosl.org --summarize --human-readable --recursive s3://openvox-artifacts/downloads/ | tail -2
```

Multiply the total by 2 (production + test buckets). Operations and network are negligible for backup workloads.

Soft-delete retains deleted/overwritten objects for 90 days at the same storage rate. In practice, this adds minimal overhead: packages are written once and never overwritten (new versions have different filenames), so soft-delete only costs extra if you delete packages (e.g., after a rollback + cleanup). Metadata is overwritten on every release but is tiny (KBs) compared to packages (GBs).

See https://cloud.google.com/storage/pricing for current rates per GiB/month.
