# Setting up offsite backups for a Laravel Cloud organization

The whole sequence, start to finish, for one organization: Ranium's own, or a
client's. At the end you have:

- **Database backups:** every database on every chosen cluster dumped nightly,
  encrypted, and uploaded by [cloud-db-backup](https://github.com/ranium/cloud-db-backup),
  a small Laravel app deployed in the organization's Laravel Cloud account, once
  per region that has clusters.
- **Storage backups:** every chosen storage bucket mirrored nightly by this
  repository's workflow, using
  [cloud-storage-backup-action](https://github.com/ranium/cloud-storage-backup-action).
- One backup bucket (AWS S3 or any S3-compatible service) holding both, with
  retention enforced by the bucket itself.
- A healthcheck per job, and a record of the setup in `deployment.md`.

Allow about an hour. A finished example is Ranium's `deployment.md` in
`ranium/cloud-backups`.

> **Secrets never go in this repository or in a chat.** Run every command that
> prints or takes a key in your own terminal. Where a value can be piped from
> one tool to another, the commands below do that, so it is never displayed.

## 0. Before you start

**Tools.** Install these on the machine you set up from (macOS or Linux), and
sign each in to the **organization being set up**, not your own:

| Tool | Used for | Install (macOS) | Sign in |
|---|---|---|---|
| `bash`, `curl`, `git` | everything | built in | |
| [Laravel Cloud CLI](https://cloud.laravel.com/docs) (`cloud`) | buckets, clusters, the database apps' variables and secrets | see its docs | `cloud auth`, in the organization's account |
| GitHub CLI (`gh`) | the config repository, its secrets and workflow runs | `brew install gh` | `gh auth login`, as someone who can set the repository's secrets |
| `jq` | reading JSON in the commands below and in `aws/deploy.sh` | `brew install jq` | |
| `age` | the encryption key pair (step 3), and restoring | `brew install age` | |
| AWS CLI (`aws`) | `aws/deploy.sh` for **every** destination (it also speaks the S3 API to Spaces), and checking the bucket | `brew install awscli` | AWS only: a profile for the account that will hold the backups (`AWS_PROFILE=...`) |
| `doctl` | DigitalOcean destination only: creating Spaces keys | `brew install doctl` | `doctl auth init --context <org>`, with an API token from the organization's DigitalOcean team that can create, read and delete Spaces keys |

**Decide, and write down in `deployment.md` as you go:**

| Decision | Example |
|---|---|
| Where backups go | AWS S3 `ap-south-1`, or DigitalOcean Spaces `blr1` |
| Backup bucket name | `<org>-offsite-backups` (globally unique on AWS) |
| Which database clusters | from `cloud database-cluster:list`; note each one's region |
| Which storage buckets | from `cloud bucket:list`; usually production only |
| Retention | defaults: daily dumps 35 days, monthly 365, previous file versions 90 |
| Run times (UTC) | storage `30 21 * * *`; databases `0 2 * * *` |
| Who holds the decryption key | the organization's owner, plus a second person or an offline copy |

Pick run times when the apps are quiet: the dumps take no locks, but they do
read every table.

## 1. The config repository

Create this organization's private config repository from the template:

```bash
gh repo create <org>/cloud-backups --private --clone
cd cloud-backups
git clone --depth 1 https://github.com/ranium/cloud-storage-backup-action /tmp/csba
command cp -R /tmp/csba/config-template/. . && rm -rf /tmp/csba
git add -A && git commit -m "Offsite backup configuration from template"
```

It holds the bucket settings (`aws/stack.json`), the storage bucket list
(`buckets.yml`), the nightly workflow, this guide, and `deployment.md`. Nothing
in it is secret.

## 2. The backup bucket

Edit [`aws/stack.json`](aws/stack.json):

```json
{
  "provider": "aws",
  "region": "ap-south-1",
  "bucket": "<org>-offsite-backups",
  "stack_name": "offsite-backups",
  "github_repository": "<org>/cloud-backups",
  "retention": { "daily_days": 35, "monthly_days": 365, "noncurrent_file_version_days": 90, "dump_version_recovery_days": 7 }
}
```

For **DigitalOcean Spaces**:

```json
{
  "provider": "digitalocean",
  "region": "blr1",
  "bucket": "<org>-offsite-backups",
  "doctl_context": "<org>",
  "github_repository": "<org>/cloud-backups",
  "retention": { "daily_days": 35, "monthly_days": 365, "noncurrent_file_version_days": 90, "dump_version_recovery_days": 7 }
}
```

For another S3-compatible provider use `"provider": "s3-compatible"` with its
`"endpoint"`, and drop the `github_*` and `stack_name` fields.

Then push the repository (the next step's GitHub detection reads it) and
create the bucket:

```bash
git push
aws/deploy.sh --plan     # shows what it would do; changes nothing
aws/deploy.sh
```

- **AWS:** uses your AWS CLI profile (`AWS_PROFILE=...`). It creates the bucket,
  an upload-only IAM user for the database apps, and a role this repository's
  workflow signs in to through GitHub OIDC, so no AWS key is ever stored in
  GitHub. The plan prints the GitHub identity the role will trust; new GitHub
  repositories use the immutable form `repo:<org>@<id>/cloud-backups@<id>`,
  which it detects through `gh`. At the end it prints the IAM user name and the
  `StorageSyncRoleArn`; keep both.
- **DigitalOcean:** needs no keys from you: it uses the `doctl` context. It
  makes a temporary full-access Spaces key, creates the bucket with it, turns
  versioning on and applies the retention rules, then deletes that key. It
  also creates the storage sync's key (`<bucket>-storage-sync`, limited to
  this bucket) and stores it as this repository's `DESTINATION_ACCESS_KEY_ID`
  and `DESTINATION_SECRET_ACCESS_KEY` secrets. The database apps' key comes in
  step 5.4. Watch the output for a warning that Spaces rejected the rules for
  previous versions: without them, replaced and deleted files are kept (and
  billed) until removed by hand. Spaces keys that can write can also delete;
  note that in `deployment.md`.
- **S3-compatible:** first `export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...`
  with the provider's keys. It creates the bucket, turns versioning on and
  applies the retention rules, and says if the provider rejected any. Then, in
  the provider's console, create **two** keys limited to this bucket: one for
  the database apps, one for the storage sync. Most providers cannot make a key
  that writes without being able to delete; note that in `deployment.md`.

The bucket has no Object Lock: an account administrator can delete anything in it.

## 3. The encryption key

```bash
age-keygen -o offsite-backups.agekey
```

- The file holds the **private key**. Put it in the organization's password
  manager, then delete it from disk. It is needed only to restore, and **losing
  it makes every database backup unreadable**.
- Its `# public key: age1…` line is the **public key**; it goes into the database
  apps and into `deployment.md`. It can only encrypt, so it is safe to share.
- For a second keyholder, generate a second pair and list both public keys,
  comma-separated: either private key can then decrypt.

## 4. Storage backups

### 4.1 List the buckets

```bash
cloud bucket:list
cloud bucket:get <bucket-name>     # shows its endpoint
```

On Laravel Cloud a bucket's **real name is its `fls-…` id**, not the label in
the dashboard; that id is also the app's `AWS_BUCKET`. Add one entry per
bucket to [`buckets.yml`](buckets.yml), with a readable `folder` and a `secret`
prefix:

```yaml
destination:
  bucket: <org>-offsite-backups
  region: ap-south-1
  prefix: files

buckets:
  - name: fls-a2b6c5a1-76fc-4593-a6eb-f8eb372fd3f8
    folder: myapp_production_private
    endpoint: https://<account>.r2.cloudflarestorage.com
    secret: MYAPP_PRODUCTION_PRIVATE
```

For DigitalOcean, set `region: blr1` (the Spaces region) and add, under
`destination`:

```yaml
  endpoint: https://blr1.digitaloceanspaces.com
  provider: DigitalOcean
```

Other S3-compatible providers are the same with their own values (see the
comments in the file).

### 4.2 Keys and settings

Create a **read-only** key for each bucket. It prints an access key id and
secret:

```bash
cloud bucket-key:create <bucket-label> --name offsite-backup-readonly --permission read_only --json --show-sensitive
```

Store them, plus the rest, in this repository's settings. `gh secret set`
prompts for each value without echoing it:

```bash
R=<org>/cloud-backups
gh secret set MYAPP_PRODUCTION_PRIVATE_ACCESS_KEY_ID -R $R
gh secret set MYAPP_PRODUCTION_PRIVATE_SECRET_ACCESS_KEY -R $R
# ...two per bucket

gh variable set AWS_ROLE_ARN -R $R --body <StorageSyncRoleArn from step 2>   # AWS
# DigitalOcean: nothing; aws/deploy.sh already set DESTINATION_* in step 2.
# Another S3-compatible destination:
gh secret set DESTINATION_ACCESS_KEY_ID -R $R
gh secret set DESTINATION_SECRET_ACCESS_KEY -R $R

gh secret set HEALTHCHECK_URL -R $R    # a healthchecks.io check for the storage sync
```

### 4.3 Run it

```bash
gh workflow run "Sync storage" -R $R -f dry-run=true   # lists only
gh workflow run "Sync storage" -R $R                   # first real copy
```

Run from `main`: on AWS the role trusts only workflows on `main`. A dry run
proves sign-in and read access but uploads nothing, so do the real run before
relying on it. Then check the bucket:

```bash
aws s3 ls s3://<org>-offsite-backups/files/ --recursive --summarize | tail -2
```

Outside AWS, add `--endpoint-url <endpoint>` and use a key that can read the
bucket. The keys `aws/deploy.sh` made on DigitalOcean are never displayed, so
there, look in the DigitalOcean console, or make a short-lived read key:
`doctl spaces keys create check --grants 'bucket=<bucket>;permission=read' -o json`,
and delete it afterwards with `doctl spaces keys delete <access key>`.

The schedule is in [`.github/workflows/sync-storage.yml`](.github/workflows/sync-storage.yml)
(`cron`, UTC).

## 5. Database backups

### 5.1 Inventory the clusters

```bash
cloud database-cluster:list
```

Note each cluster's **name**, **region** and **hostname**. Private database
endpoints are reachable only from the same region, so you need **one
cloud-db-backup app per region** that has clusters, each backing up the
clusters in its region. The private hostname is the cluster's hostname without
`.public` (`db-….<region>.db.laravel.cloud`). A public cluster can be backed up
from any region.

### 5.2 Create one app per region

In Laravel Cloud, create an application from the GitHub repository
`ranium/cloud-db-backup` (branch `main`) in that region, e.g.
`db-backup-us-east-2`. On its environment:

- **Build command:**
  ```
  composer install --no-dev --optimize-autoloader
  bin/install-age
  ```
- **Deploy command:** empty (there are no migrations).
- **Compute:** smallest size, one replica, **scheduler on**, **no database attached**.
- **Hibernation:** a hibernating app still wakes for its scheduled run, but
  stays awake only for its sleep timeout. Either turn hibernation off, or keep
  it on and make sure the sleep timeout comfortably exceeds a run (normally
  seconds, plus up to 5 minutes when a suspended cluster has to wake).

### 5.3 Variables

Find the environment id, then add the variables. `append` adds without
touching existing ones (never use `set`, which replaces them all):

```bash
cloud environment:list db-backup-us-east-2
E=<env-id>
add() { cloud env:vars "$E" --action append --key "$1" --value "$2" --force; }

add BACKUP_DEPLOYMENT  <org>-us-east-2              # unique per app; names the manifests
add BACKUP_CLUSTERS    my-cluster                   # comma-separated, this region's clusters
add BACKUP_SCHEDULE    "0 2 * * *"                  # cron, UTC
add BACKUP_S3_BUCKET   <org>-offsite-backups
add BACKUP_S3_REGION   ap-south-1
add BACKUP_AGE_RECIPIENTS age1...                   # the public key(s) from step 3
add BACKUP_HEALTHCHECK_URL https://hc-ping.com/...  # a separate check per app

# per cluster: NAME is the cluster name upper-cased, non-alphanumerics -> "_"
add BACKUP_CLUSTER_MY_CLUSTER_DRIVER   mysql
add BACKUP_CLUSTER_MY_CLUSTER_HOST     db-....us-east-2.db.laravel.cloud
add BACKUP_CLUSTER_MY_CLUSTER_PORT     3306
add BACKUP_CLUSTER_MY_CLUSTER_USERNAME "$(cloud database-cluster:get <cluster-id> --json | jq -r '.connection.username')"
```

For an S3-compatible destination also add `BACKUP_S3_ENDPOINT`, and an empty
`BACKUP_S3_STORAGE_CLASS` for providers without storage classes. On
DigitalOcean that is:

```bash
add BACKUP_S3_REGION   blr1
add BACKUP_S3_ENDPOINT https://blr1.digitaloceanspaces.com
add BACKUP_S3_STORAGE_CLASS ""         # empty; if the CLI refuses an empty value, set it in the dashboard
```

Every option is in cloud-db-backup's README.

### 5.4 Secrets

Laravel Cloud secrets are organization-level, take their value from standard
input, and are attached to environments. Pipe values in so they are never
displayed:

```bash
# The cluster's password, straight from Cloud:
cloud database-cluster:get <cluster-id> --json --show-sensitive | jq -j '.connection.password' \
  | cloud secret:create --name BACKUP_CLUSTER_MY_CLUSTER_PASSWORD --notes "my-cluster password, for cloud-db-backup" --json

# The upload key, once per organization, shared by every app (AWS):
aws iam create-access-key --user-name <DatabaseUploader user from step 2> --output json > /tmp/k.json
jq -j .AccessKey.AccessKeyId /tmp/k.json | cloud secret:create --name BACKUP_S3_KEY --json
jq -j .AccessKey.SecretAccessKey /tmp/k.json | cloud secret:create --name BACKUP_S3_SECRET --json
rm -P /tmp/k.json
# DigitalOcean: instead of the four lines above, from this repository
#   aws/deploy.sh --db-key "$E"
# creates the Spaces key (once), stores it as BACKUP_S3_KEY / BACKUP_S3_SECRET
# and attaches both to the environment. Run it for every app.
# Another S3-compatible provider: pipe in the database-app key from step 2.

cloud secret:list                                    # ids
cloud environment-secret:attach "$E" <password-secret-id> <s3-key-id> <s3-secret-id>
cloud environment-secret:list "$E"                   # check
```

An IAM user can hold at most two access keys; keep one slot free for rotation.

### 5.5 Deploy and run

Deploy the environment (variables take effect on deploy), then check the build
log for `install-age: installed age ... for arm64 and amd64`. From the
environment's console:

```bash
php artisan schedule:list                 # shows BACKUP_SCHEDULE
php artisan backup:databases --dry-run    # connects and lists the databases
php artisan backup:databases              # a real run now
```

Then check the run's manifest (outside AWS, add `--endpoint-url`): it lists
every database with its size and SHA-256, and `"successful": true`:

```bash
aws s3 ls s3://<org>-offsite-backups/db/manifests/<org>-us-east-2/ --recursive | tail -1
aws s3 cp s3://<org>-offsite-backups/db/manifests/<that key> - | jq '.successful, [.clusters[].databases[] | {database, successful, bytes}]'
```

Repeat 5.2 to 5.5 for each region.

## 6. Monitoring

Create one [healthchecks.io](https://healthchecks.io) check per job (the
storage sync and each database app), each with the job's cron schedule and a
grace period of about an hour. A job pings on success and `/fail` on failure,
so a check alerts both when a run fails and when it never ran.

The morning after setup, confirm every check received a ping from the
**scheduled** run, not just the manual ones.

## 7. Restore drill

Before calling it done, restore one dump into a scratch database, following
[cloud-db-backup/RESTORE.md](https://github.com/ranium/cloud-db-backup/blob/main/RESTORE.md),
and check its row counts. Log the date and result in `deployment.md`. Repeat
every few months and after changes to the backup app.

## 8. Record it

Fill in [`deployment.md`](deployment.md) with what was created (names, ids,
regions, schedules, which key is where; never the secret values), commit and
push. That file is how anyone, later, finds out what this organization's
backups are and how they run.

## Gotchas

- **Bucket names:** use the `fls-…` id, not the dashboard label.
- **GitHub sign-in to AWS fails** with `Not authorized to perform
  sts:AssumeRoleWithWebIdentity`: the role trusts a different repository
  identity. Re-run `aws/deploy.sh` with `gh` installed (it detects the
  immutable subject format), and run the workflow from `main`.
- **`cloud env:vars --action set` replaces every variable**, including
  `APP_KEY`. Use `append`.
- **`cloud command:run` sometimes fails with "Maximum attempts reached"** for
  long commands; run them from the environment's console instead.
- **Variables and secrets apply only after a deploy.**
- **Changing `stack.json`:** re-run `aws/deploy.sh`; CloudFormation updates the
  bucket in place.
- **Updating the code:** both the workflow and `aws/deploy.sh` pin commit SHAs;
  bump them deliberately. The database apps deploy `main` of cloud-db-backup.
- **DigitalOcean: "exists but ... lacks its secrets".** A Spaces key's secret
  cannot be read back after it is created, so if a key exists but its secrets
  were never stored (or were deleted), `aws/deploy.sh` stops and prints the
  `doctl spaces keys delete` command; run it, then run `aws/deploy.sh` again.
- **DigitalOcean: `doctl` 403 errors.** The API token lacks a Spaces key scope,
  or belongs to another team. Make a token in the organization's team with
  create, read and delete on Spaces keys.
