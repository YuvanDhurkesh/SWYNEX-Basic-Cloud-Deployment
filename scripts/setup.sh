#!/usr/bin/env bash
# One-time infrastructure setup for CloudNotes Lite:
#   private S3 bucket  ->  CloudFront distribution with Origin Access Control (OAC)
#
# Usage:   ./scripts/setup.sh
# Needs:   AWS CLI v2 with credentials allowed to manage S3 and CloudFront.
# Writes:  .deploy-state (bucket name, distribution ID, domain), read by deploy.sh,
#          verify.sh and teardown.sh.
set -euo pipefail

# Git Bash on Windows rewrites arguments that start with "/" into Windows paths.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-ap-south-1}"
PROJECT="swynex-basic-cloud-deployment"
STATE_FILE=".deploy-state"
WORK=".build"

# AWS managed policies (same IDs in every account)
CACHE_POLICY_CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"
RESPONSE_HEADERS_SECURITY="67f7725c-6f97-4210-82d7-5512b31e9d03"

if [[ -f "$STATE_FILE" ]]; then
  echo "A deployment already exists ($STATE_FILE). Run ./scripts/teardown.sh first, or ./scripts/deploy.sh to update it." >&2
  exit 1
fi

mkdir -p "$WORK"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SUFFIX="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || true)"
BUCKET="swynex-cloudnotes-lite-${SUFFIX}"
echo "Region:  $REGION"
echo "Bucket:  $BUCKET"

echo "[1/6] Creating private S3 bucket"
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT},{Key=Owner,Value=SWYNEX-Internship}]"

echo "[2/6] Creating CloudFront Origin Access Control"
OAC_ID="$(aws cloudfront create-origin-access-control \
  --origin-access-control-config \
  "Name=${BUCKET}-oac,Description=OAC for ${BUCKET},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
  --query 'OriginAccessControl.Id' --output text)"
echo "        OAC ID: $OAC_ID"

echo "[3/6] Creating CloudFront distribution"
ORIGIN_ID="s3-${BUCKET}"
cat >"$WORK/distribution.json" <<JSON
{
  "DistributionConfig": {
    "CallerReference": "${BUCKET}-$(date +%s)",
    "Comment": "CloudNotes Lite (SWYNEX Task 2)",
    "Enabled": true,
    "DefaultRootObject": "index.html",
    "PriceClass": "PriceClass_200",
    "HttpVersion": "http2and3",
    "IsIPV6Enabled": true,
    "Origins": {
      "Quantity": 1,
      "Items": [
        {
          "Id": "${ORIGIN_ID}",
          "DomainName": "${BUCKET}.s3.${REGION}.amazonaws.com",
          "OriginAccessControlId": "${OAC_ID}",
          "S3OriginConfig": { "OriginAccessIdentity": "" }
        }
      ]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "${ORIGIN_ID}",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "${CACHE_POLICY_CACHING_OPTIMIZED}",
      "ResponseHeadersPolicyId": "${RESPONSE_HEADERS_SECURITY}",
      "Compress": true,
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"],
        "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
      }
    },
    "CustomErrorResponses": {
      "Quantity": 2,
      "Items": [
        { "ErrorCode": 403, "ResponsePagePath": "/404.html", "ResponseCode": "404", "ErrorCachingMinTTL": 60 },
        { "ErrorCode": 404, "ResponsePagePath": "/404.html", "ResponseCode": "404", "ErrorCachingMinTTL": 60 }
      ]
    }
  },
  "Tags": {
    "Items": [
      { "Key": "Project", "Value": "${PROJECT}" },
      { "Key": "Owner", "Value": "SWYNEX-Internship" }
    ]
  }
}
JSON

read -r DIST_ID DIST_DOMAIN DIST_ARN < <(aws cloudfront create-distribution-with-tags \
  --distribution-config-with-tags "file://$WORK/distribution.json" \
  --query 'Distribution.[Id,DomainName,ARN]' --output text)
echo "        Distribution: $DIST_ID ($DIST_DOMAIN)"

cat >"$STATE_FILE" <<STATE
REGION=$REGION
BUCKET=$BUCKET
OAC_ID=$OAC_ID
DIST_ID=$DIST_ID
DIST_DOMAIN=$DIST_DOMAIN
STATE

echo "[4/6] Allowing only this distribution to read the bucket"
cat >"$WORK/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
        }
      }
    }
  ]
}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$WORK/bucket-policy.json"

echo "[5/6] Uploading the site"
./scripts/deploy.sh --no-invalidate

echo "[6/6] Waiting for CloudFront to finish deploying (usually 3-10 minutes)"
aws cloudfront wait distribution-deployed --id "$DIST_ID"

echo
echo "Live URL: https://$DIST_DOMAIN"
