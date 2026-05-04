# Secrets

All env vars with a `_B64` suffix contain base64-encoded binary or multiline data. Everything else is plain text. If you need the values we use for some reason, contact Overlook InfraTech.

## Generating secrets

**GPG key (RPM + DEB signing):**

```bash
gpg --export-secret-keys --armor openvox@voxpupuli.org | base64 -w0
```
or
```bash
base64 -w < GPG-KEY-openvox
```

**AWS credentials (S3 at s3.osuosl.org):**

From the OSU OSL account. No encoding needed.

**GCS (backup/restore):**

No secrets needed. Locally, authenticate with `gcloud auth login`. In CI, Workload Identity Federation handles auth automatically (see [GCS setup](gcs-setup.md)).

**MSI signing (DigiCert ONE / KeyLocker):**

1. `WINDOWS_SM_API_KEY`: Create an API token in DigiCert ONE > API Tokens.
2. `WINDOWS_SM_HOST`: The DigiCert ONE auth endpoint (e.g., `https://clientauth.one.digicert.com`).
3. `WINDOWS_SM_CLIENT_CERT_B64`: `base64 -w0 < client_cert.p12`
4. `WINDOWS_SM_CLIENT_CERT_PASSWORD`: The password set when the .p12 was created.
5. `WINDOWS_CERT_ALIAS`: The cert alias from DigiCert ONE > Certificates.

**MacOS signing:**

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

## GitHub Actions secrets

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

## Local secrets file

You can manage the secrets however you want, but keeping them in a file you can easily `source` is probably easiest.

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
