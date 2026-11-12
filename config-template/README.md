# Offsite backups: configuration

> Setting this up for a new organization? Follow [SETUP.md](SETUP.md) from the top.
> What is deployed for this organization is recorded in [deployment.md](deployment.md).

This private repository holds this organization's backup settings. The code
lives in two public repositories:

- [ranium/cloud-db-backup](https://github.com/ranium/cloud-db-backup): the
  database backup app on Laravel Cloud, and the bucket setup.
- [ranium/cloud-storage-backup-action](https://github.com/ranium/cloud-storage-backup-action):
  the storage sync this repository's workflow runs.

Nothing in this repository is secret. Keys live in GitHub secrets and in each
Laravel Cloud environment's variables.

## 1. The backup bucket

Edit [`aws/stack.json`](aws/stack.json):

| Field | |
|---|---|
| `provider` | `aws`, `digitalocean`, or `s3-compatible` for Backblaze B2, MinIO, ... |
| `region`, `bucket` | Where backups go. |
| `endpoint` | `s3-compatible`: required. `digitalocean`: defaults to `https://<region>.digitaloceanspaces.com`. |
| `doctl_context` | `digitalocean` only: the `doctl auth` context for the right team. |
| `retention` | Days to keep daily dumps (35), monthly dumps (365) and previous file versions (90). |
| `github_repository` | This repository, as `owner/repo`. `aws`: the repository the sync role trusts. `digitalocean`: where the storage sync's key is stored. |

Then:

```bash
aws/deploy.sh --plan   # what would change
aws/deploy.sh          # apply
```

It prints the next steps. On AWS that is: create the database uploader's
access key, and set the printed `StorageSyncRoleArn` as this repository's
`AWS_ROLE_ARN` **variable** (Settings → Secrets and variables → Actions →
Variables). On DigitalOcean it has already stored the storage sync's key in
this repository; once a database app exists, `aws/deploy.sh --db-key <environment id>`
gives it its key. Re-run it whenever you change `stack.json`.

Tools it needs: `bash`, `curl`, `jq` and the AWS CLI; for DigitalOcean also
`doctl` and `gh`, and the Laravel Cloud CLI (`cloud`) for `--db-key`. The full
list, with how to sign each in, is in [SETUP.md](SETUP.md#0-before-you-start).

## 2. Storage buckets

List them in [`buckets.yml`](buckets.yml). On Laravel Cloud a bucket's real
name is its `fls-...` id, not the label shown in the dashboard: take it from
`cloud bucket:list`, and give it a readable `folder`. For each one, create a
**read-only** access key limited to that bucket and add two repository
**secrets** named after its `secret` value:

```
<SECRET>_ACCESS_KEY_ID
<SECRET>_SECRET_ACCESS_KEY
```

For a destination that is not AWS, `DESTINATION_ACCESS_KEY_ID` and
`DESTINATION_SECRET_ACCESS_KEY` hold its key: on DigitalOcean `aws/deploy.sh`
sets them, elsewhere add them yourself.

Optional: a `HEALTHCHECK_URL` secret (a healthchecks.io ping URL) gets a ping
after every nightly run, or a failure ping if any bucket failed. Without it,
nothing is sent.

## 3. Check it

Actions → **Sync storage** → **Run workflow**, with *dry run* ticked first.
Each bucket's job shows what it copied or would copy. A dry run only lists, so
also run one real sync before relying on it.

Run it from the `main` branch: on AWS the sign-in role only trusts workflows
running on `main` (`github_branch` in `stack.json`), and jobs that use a GitHub
`environment:` are not trusted either.

Runs never overlap. If one is still going when the next is due, the next
waits; GitHub keeps at most one waiting run, so a third is dropped, which a
healthcheck will report as missing.

## 4. Databases

Deploy [cloud-db-backup](https://github.com/ranium/cloud-db-backup) on
Laravel Cloud once per region that has database clusters, pointing it at the
same bucket. Its README lists the variables.

## Restoring

- Databases: [cloud-db-backup/RESTORE.md](https://github.com/ranium/cloud-db-backup/blob/main/RESTORE.md)
- Files: [cloud-storage-backup-action/README.md](https://github.com/ranium/cloud-storage-backup-action#restoring-files)
