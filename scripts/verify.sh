#!/usr/bin/env bash
# Check that the deployment behaves as designed.
#
# Usage:   ./scripts/verify.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .deploy-state

URL="https://$DIST_DOMAIN"
pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    printf '  PASS  %-48s %s\n' "$name" "$actual"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-48s got "%s", expected "%s"\n' "$name" "$actual" "$expected"
    fail=$((fail + 1))
  fi
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -sI "$1" | tr -d '\r' | grep -i "^$2:" | head -1 | cut -d' ' -f2-; }

echo "Checking $URL"
check "Home page over HTTPS returns 200"               "200" "$(status "$URL/")"
check "HTTP redirects to HTTPS"                        "301" "$(status "http://$DIST_DOMAIN/")"
check "Home page Content-Type"                          "text/html" "$(header "$URL/" content-type)"
check "Stylesheet returns 200"                          "200" "$(status "$URL/styles.css")"
check "Script Content-Type"                             "javascript" "$(header "$URL/app.js" content-type)"
check "Unknown path returns custom 404"                 "404" "$(status "$URL/does-not-exist")"
check "404 body is the custom error page"               "page not found" "$(curl -s "$URL/does-not-exist" | grep -o 'page not found' | head -1)"
check "HSTS header present"                             "max-age" "$(header "$URL/" strict-transport-security)"
check "X-Content-Type-Options header present"           "nosniff" "$(header "$URL/" x-content-type-options)"
check "Served by CloudFront"                            "cloudfront" "$(header "$URL/" via)"
check "Direct S3 access is blocked"                     "403" "$(status "https://$BUCKET.s3.$REGION.amazonaws.com/index.html")"
check "Bucket blocks all public access"                 "True	True	True	True" \
  "$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
