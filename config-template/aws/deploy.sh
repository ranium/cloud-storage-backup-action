#!/usr/bin/env bash
#
# Creates or updates this organization's backup bucket from aws/stack.json.
#
#   aws/deploy.sh --plan                    show what would change
#   aws/deploy.sh                           apply it
#   aws/deploy.sh --db-key <environment>    DigitalOcean: give a cloud-db-backup
#                                           environment the database key
#
# The bucket logic lives in ranium/cloud-db-backup (aws/setup-bucket and the
# CloudFormation template). It is fetched at the pinned ref below, so this
# repository only holds this organization's values. Bump the ref deliberately.
#
# AWS: uses your AWS CLI profile (AWS_PROFILE).
# DigitalOcean: uses doctl (the context in doctl_context), gh and, for
# --db-key, the Laravel Cloud CLI; no keys to set.
# S3-compatible: set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to the
# provider's keys first.
#
# Needs bash, curl, jq and the AWS CLI; see SETUP.md for the full list.

set -euo pipefail

CLOUD_DB_BACKUP_REF="fd739ea12e549e15ae29711d7bf152cdd84c6641" # a commit SHA; bump deliberately

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

base="https://raw.githubusercontent.com/ranium/cloud-db-backup/${CLOUD_DB_BACKUP_REF}/aws"

for file in setup-bucket backup-bucket.yml; do
    curl -fsSL -o "${work}/${file}" "${base}/${file}"
done

bash "${work}/setup-bucket" "${here}/stack.json" "$@"
