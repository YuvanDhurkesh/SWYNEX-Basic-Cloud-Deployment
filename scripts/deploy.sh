#!/usr/bin/env bash
# Upload site/ to the S3 bucket and clear the CloudFront cache.
#
# Usage:   ./scripts/deploy.sh [--no-invalidate]
# Needs:   .deploy-state written by setup.sh.
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .deploy-state

SITE_DIR="site"
VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo untracked)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%MZ)"

# Stamp the build so the live page shows which commit it is serving.
# The stamped file is generated in .build/ and uploaded in place of site/build.js.
mkdir -p .build
STAMPED_BUILD_JS=".build/build.js"
printf 'window.CLOUDNOTES_BUILD = { version: "%s", builtAt: "%s" };\n' "$VERSION" "$BUILT_AT" >"$STAMPED_BUILD_JS"

# Set Content-Type explicitly: guessing from the local OS can be wrong on Windows.
content_type() {
  case "$1" in
    *.html) echo "text/html; charset=utf-8" ;;
    *.css)  echo "text/css; charset=utf-8" ;;
    *.js)   echo "application/javascript; charset=utf-8" ;;
    *.svg)  echo "image/svg+xml" ;;
    *.png)  echo "image/png" ;;
    *.ico)  echo "image/x-icon" ;;
    *)      echo "application/octet-stream" ;;
  esac
}

# HTML is revalidated on every request; other assets may be cached for 5 minutes.
cache_control() {
  case "$1" in
    *.html) echo "no-cache" ;;
    *)      echo "public, max-age=300" ;;
  esac
}

echo "Uploading $SITE_DIR/ to s3://$BUCKET (build $VERSION)"
while IFS= read -r -d '' file; do
  key="${file#"$SITE_DIR"/}"
  src="$file"
  [[ "$key" == "build.js" ]] && src="$STAMPED_BUILD_JS"
  aws s3 cp "$src" "s3://$BUCKET/$key" \
    --content-type "$(content_type "$file")" \
    --cache-control "$(cache_control "$file")" \
    --only-show-errors
  echo "  uploaded $key"
done < <(find "$SITE_DIR" -type f -print0)

# Remove objects that no longer exist locally.
for key in $(aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output text); do
  [[ "$key" == "None" ]] && continue
  if [[ ! -f "$SITE_DIR/$key" ]]; then
    aws s3 rm "s3://$BUCKET/$key" --only-show-errors
    echo "  removed $key"
  fi
done

if [[ "${1:-}" != "--no-invalidate" ]]; then
  INV_ID="$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/*' \
    --query 'Invalidation.Id' --output text)"
  echo "Invalidating CloudFront cache ($INV_ID)"
  aws cloudfront wait invalidation-completed --distribution-id "$DIST_ID" --id "$INV_ID"
fi

echo "Done: https://$DIST_DOMAIN"
