#!/usr/bin/env bash
# Upload one image/video to the public PR-assets bucket and print its public URL.
# Usage: upload.sh <file> [content-type-override]
# Stdout: the public URL only (progress/errors go to stderr) so `url=$(upload.sh f)` is safe.
#
# Cwd-independent: this script reads nothing from the repo it is invoked in — no
# .infisical.json, no .env, no AWS profile. Run it from anywhere.
set -euo pipefail

PROJECT_ID="75f1046c-8450-4039-92fd-14472c6a0bd7"
BUCKET="subhanio-pr-assets"
REGION="eu-west-2"
INFISICAL_ENV="${PR_ASSETS_INFISICAL_ENV:-prod}"  # override with PR_ASSETS_INFISICAL_ENV=dev

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "usage: upload.sh <file> [content-type]   (file must exist)" >&2
  exit 1
fi

for bin in infisical aws; do
  command -v "$bin" >/dev/null 2>&1 || { echo "upload.sh: '$bin' not found on PATH" >&2; exit 1; }
done

# Extension from the basename only — a dot in a parent directory must not become the
# extension, and an extensionless file must not turn the whole name into one.
base="$(basename "$file")"
ext="${base##*.}"
if [ "$ext" = "$base" ]; then ext="bin"; fi
ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

# Content-Type matters: wrong type makes browsers download instead of render inline.
ct="${2:-}"
if [ -z "$ct" ]; then
  case "$ext" in
    png)        ct="image/png" ;;
    jpg|jpeg)   ct="image/jpeg" ;;
    gif)        ct="image/gif" ;;
    webp)       ct="image/webp" ;;
    svg)        ct="image/svg+xml" ;;
    mp4)        ct="video/mp4" ;;
    mov)        ct="video/quicktime" ;;
    webm)       ct="video/webm" ;;
    *)          ct="application/octet-stream" ;;
  esac
fi

# Random, date-bucketed key — unguessable-ish, never collides.
uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key="pr/$(date +%Y/%m)/${uuid}.${ext}"

# Creds come from Infisical (the scoped pr-assets-uploader user), injected as
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY which the aws CLI picks up automatically.
#
# --projectId and --path are load-bearing: without --projectId, `infisical run` resolves
# the project from the nearest .infisical.json, so invoking this from any repo with its
# own Infisical config would look up /pr-assets in THAT project and 404. With the id
# passed explicitly it wins over the local config, which is what makes this repo-agnostic.
infisical run --projectId "$PROJECT_ID" --env "$INFISICAL_ENV" --path /pr-assets --silent -- \
  aws s3 cp "$file" "s3://${BUCKET}/${key}" --content-type "$ct" --region "$REGION" >&2

echo "https://${BUCKET}.s3.${REGION}.amazonaws.com/${key}"
