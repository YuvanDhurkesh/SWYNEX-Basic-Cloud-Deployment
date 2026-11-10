#!/usr/bin/env bash
# Delete everything setup.sh created: distribution, OAC, bucket (all object versions).
#
# Usage:   ./scripts/teardown.sh
# CloudFront must disable a distribution before deleting it, which takes several minutes.
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .deploy-state
mkdir -p .build

read -r -p "Delete distribution $DIST_ID and bucket $BUCKET? Type 'yes': " answer
[[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 1; }

echo "[1/4] Disabling CloudFront distribution"
ETAG="$(aws cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)"
aws cloudfront get-distribution-config --id "$DIST_ID" --query DistributionConfig --output json \
  | sed 's/"Enabled": true/"Enabled": false/' >.build/disabled-config.json
aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
  --distribution-config file://.build/disabled-config.json >/dev/null
aws cloudfront wait distribution-deployed --id "$DIST_ID"

echo "[2/4] Deleting distribution"
ETAG="$(aws cloudfront get-distribution --id "$DIST_ID" --query ETag --output text)"
aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG"

echo "[3/4] Deleting Origin Access Control"
ETAG="$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query ETag --output text)"
aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$ETAG"

echo "[4/4] Emptying and deleting bucket (including old versions)"
while true; do
  aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 \
    --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json >.build/delete.json
  grep -q '"Key"' .build/delete.json || break
  aws s3api delete-objects --bucket "$BUCKET" --delete file://.build/delete.json >/dev/null
done
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"

rm -f .deploy-state
echo "Teardown complete."
