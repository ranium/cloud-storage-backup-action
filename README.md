# cloud-storage-backup-action

A GitHub Action that mirrors an S3-compatible bucket, such as a Laravel Cloud
(Cloudflare R2) storage bucket, into an offsite backup bucket on AWS S3 or any
other S3-compatible provider. It runs [rclone](https://rclone.org), installed
at a pinned version and verified against a pinned checksum.

Databases are backed up separately by
[cloud-db-backup](https://github.com/ranium/cloud-db-backup). Both write into
the same bucket: dumps under `db/`, storage mirrors under `files/`.

## How it is meant to be used

This repository is the **engine**. Each organization keeps a small **private
config repository** that lists its buckets and holds its secrets; its workflow
calls this Action once per bucket, in parallel. Start one from
[`config-template/`](config-template):

```
<your-org>/cloud-backups/          (private)
├── aws/
│   ├── stack.json                 the backup bucket: provider, region, name, retention
│   └── deploy.sh                  creates/updates it (uses cloud-db-backup's setup-bucket)
├── buckets.yml                    the buckets to mirror, and the destination
└── .github/workflows/
    └── sync-storage.yml           nightly at 03:00 IST, plus a manual "Run workflow" button
```

To set up a new organization, both database and storage backups, follow
[config-template/SETUP.md](config-template/SETUP.md) from the top. Its first
section lists the tools the setup needs (the Laravel Cloud CLI, `gh`, `jq`,
`age`, the AWS CLI, and `doctl` for a DigitalOcean Spaces destination). The
Action itself needs nothing installed: it runs on GitHub's Linux runners and
fetches its own rclone.

## What a sync does

- Copies new and changed files, compared by size and MD5. Files uploaded in
  one part carry their MD5 in the bucket listing, so checking them is cheap;
  files uploaded in parts (large ones) need one extra request per side each
  night, and where no MD5 exists only sizes are compared.
- Propagates deletions. On a versioned destination, which `setup-bucket`
  creates, a deletion leaves the previous version in place until the bucket's
  lifecycle rules expire it (90 days by default).
- **Stops after `max-delete` deletions** (1000 by default) and fails the run,
  so a source emptied by mistake cannot wipe the mirror in one night.
- Writes a per-bucket summary to the workflow run page.

No rclone config file is written: both remotes are configured through
environment variables for the length of the step. No ACL is sent, so it works
with buckets that have ACLs disabled (the AWS default, and what `setup-bucket`
creates).

On S3 Standard-IA (the AWS default here), every object is billed as at least
128 KB for at least 30 days. A bucket of many small files (thumbnails) can cost
more there than in S3 Standard; set `storage-class: STANDARD` for it if so.

## Inputs

| Input | Default | |
|---|---|---|
| `source-bucket` | — | Bucket to back up. |
| `source-endpoint` | — | e.g. `https://<account>.r2.cloudflarestorage.com` |
| `source-access-key-id` / `source-secret-access-key` | — | A **read-only** key for that bucket. |
| `source-provider` | `Cloudflare` | rclone's S3 provider name. |
| `source-region` | `auto` | |
| `destination-bucket` | — | |
| `destination-region` | — | |
| `destination-prefix` | `files` | |
| `destination-folder` | source bucket name | Folder under the prefix: the source lands in `<prefix>/<folder>/`. |
| `destination-endpoint` | empty | Empty means AWS S3. |
| `destination-provider` | `AWS` / `Other` | rclone's S3 provider name, e.g. `DigitalOcean`. |
| `destination-access-key-id` / `destination-secret-access-key` | empty | Leave empty on AWS after `aws-actions/configure-aws-credentials` (OIDC). |
| `storage-class` | `STANDARD_IA` | Empty sends none, for providers without storage classes. |
| `max-delete` | `1000` | |
| `transfers` | `16` | Files copied in parallel. |
| `dry-run` | `false` | Report what would change; change nothing. |

Output: `max-delete-reached` is `"true"` when a run stopped at `max-delete`.

## Example

```yaml
- uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
  with:
    role-to-assume: ${{ vars.AWS_ROLE_ARN }}
    aws-region: ap-south-1

- uses: ranium/cloud-storage-backup-action@b2c7f98cc9df6efa4bd668b354d15d768ac4dc11 # pin a commit
  with:
    source-bucket: laratix_production_private
    source-endpoint: https://<account>.r2.cloudflarestorage.com
    source-access-key-id: ${{ secrets.LARATIX_PRODUCTION_PRIVATE_ACCESS_KEY_ID }}
    source-secret-access-key: ${{ secrets.LARATIX_PRODUCTION_PRIVATE_SECRET_ACCESS_KEY }}
    destination-bucket: ranium-offsite-backups
    destination-region: ap-south-1
```

## Restoring files

Copy a folder back with rclone, from a machine with read access to the backup
bucket. The latest version of every file is what a plain copy returns:

```bash
rclone copy :s3,provider=AWS,env_auth=true,region=ap-south-1:ranium-offsite-backups/files/laratix_production_private ./restore
```

From DigitalOcean Spaces (or another S3-compatible provider), name the
provider and endpoint instead, with a key that can read the bucket in
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. The endpoint is quoted because it
contains a `:`:

```bash
rclone copy ':s3,provider=DigitalOcean,env_auth=true,endpoint="https://blr1.digitaloceanspaces.com":client-offsite-backups/files/myapp_production_private' ./restore
```

A file deleted or overwritten in the source is still in the mirror as a
previous version until the retention period ends. List and fetch those with
`aws s3api list-object-versions` and `aws s3api get-object --version-id`.

## License

MIT. See [LICENSE](LICENSE).
