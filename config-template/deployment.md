# Offsite backups: what is deployed

The record of this organization's setup, filled in while following
[SETUP.md](SETUP.md). Nothing here is secret: list keys and secrets by name,
never by value. Last updated: <date>.

## Overview

| What | Runs on | When (UTC) | Covers | Healthcheck |
|---|---|---|---|---|
| Storage sync | GitHub Actions, this repository | `30 21 * * *` | <n> buckets | `HEALTHCHECK_URL` secret |
| Database backup | Laravel Cloud app `<app>` | `<cron>` | cluster `<name>` | app's `BACKUP_HEALTHCHECK_URL` |

## Backup bucket

- **Bucket:** `<provider>://<bucket>`, region `<region>`, account `<account>`.
- **Created by:** `aws/deploy.sh` from `aws/stack.json` (stack `<stack name>` on AWS).
- **Retention:** daily dumps <35> days, monthly <365>, replaced dump versions <7>,
  previous file versions <90>.
- **Access:**
  - Database apps: <IAM user / provider key name>, key ending `…<last 4>`, stored in Laravel
    Cloud as `BACKUP_S3_KEY` / `BACKUP_S3_SECRET`.
  - Storage sync: <role ARN in `AWS_ROLE_ARN`, or provider key in `DESTINATION_*` secrets>.

## Storage sync

| Source bucket (`fls-…`) | Mirrored to |
|---|---|
| `<fls-id>` | `files/<folder>/` |

GitHub settings: <variables and secrets, by name>.

## Database backups

| | `<app>` |
|---|---|
| Region / environment | `<region>` / `<env-id>` |
| `BACKUP_DEPLOYMENT` | `<name>` |
| `BACKUP_CLUSTERS` | `<clusters>` |
| Cluster host | `<private host>` |
| `BACKUP_SCHEDULE` | `<cron>` |
| Databases | <list at setup time> |
| Secrets attached | <names> |
| Hibernation | <on/off, and how runs are kept awake> |

Encryption public key: `age1…`. Private key held by: <who / where>.

## Not backed up (by decision)

- <cluster or bucket, and why>

## Restore drills

| Date | Database | Result |
|---|---|---|
| | | |

## History

- <date>: set up.
