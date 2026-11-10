# Setup steps

These are the steps used to deploy CloudNotes Lite to Amazon S3 and Amazon CloudFront. [`scripts/setup.sh`](../scripts/setup.sh) runs all of them with the AWS CLI. Each step below gives the CLI command and the matching AWS Console action, so either route works.

## Prerequisites

| Requirement | Check |
|---|---|
| AWS account and an IAM user or role allowed to manage S3 and CloudFront | `aws sts get-caller-identity` |
| AWS CLI v2 | `aws --version` |
| Bash (Linux, macOS, or Git Bash on Windows) and `curl` | `bash --version` |
| Git | `git --version` |

Configure credentials once with `aws configure`, and set the default region to `ap-south-1` (Mumbai).

This deployment was run from Windows 11 with Git Bash and AWS CLI 2.36.

On Git Bash for Windows, the scripts set `MSYS_NO_PATHCONV=1`. Without it, Git Bash turns arguments such as `/*` and `/404.html` into Windows paths before the AWS CLI sees them.

## Step 1: Create a private S3 bucket

The bucket stores the site files. It is not a public "static website" bucket: nobody can read it directly, and CloudFront is the only way in.

```bash
BUCKET=swynex-cloudnotes-lite-<random>
REGION=ap-south-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint=$REGION

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
```

**Console:** S3 → Create bucket → choose a globally unique name and the `ap-south-1` region → leave **Block all public access** ticked → enable **Bucket Versioning** → keep the default encryption (SSE-S3) → Create bucket.

Why these settings:

- **Block Public Access** stops anyone from making the bucket or its objects public by mistake.
- **SSE-S3 encryption** encrypts objects at rest at no extra cost.
- **Versioning** keeps earlier copies of each file, so a bad upload can be rolled back.

## Step 2: Create an Origin Access Control (OAC)

OAC lets CloudFront sign its requests to S3 with SigV4, so the bucket can trust CloudFront without being public. It replaces the older Origin Access Identity (OAI).

```bash
aws cloudfront create-origin-access-control --origin-access-control-config \
  "Name=${BUCKET}-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3"
```

**Console:** CloudFront → Origin access → Create control setting → Signing behaviour **Sign requests** → Origin type **S3**.

## Step 3: Create the CloudFront distribution

The full configuration is written to `.build/distribution.json` by the setup script. The main settings:

| Setting | Value | Reason |
|---|---|---|
| Origin | `<bucket>.s3.ap-south-1.amazonaws.com` with the OAC from step 2 | Uses the S3 REST endpoint, which works with OAC; the S3 website endpoint does not |
| Default root object | `index.html` | Requests for `/` return the home page |
| Viewer protocol policy | Redirect HTTP to HTTPS | All traffic is encrypted |
| Cache policy | AWS managed `CachingOptimized` | Long edge caching with gzip and Brotli |
| Response headers policy | AWS managed `SecurityHeadersPolicy` | Adds HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and `X-XSS-Protection` |
| Allowed methods | GET, HEAD | The site is read-only |
| Custom error responses | 403 and 404 → `/404.html` with status 404 | S3 returns 403 for a missing key when the caller cannot list the bucket, so both map to the custom page |
| Price class | `PriceClass_200` | Includes edge locations in India, without paying for every region |
| HTTP versions | HTTP/2 and HTTP/3 | Faster page loads |
| IPv6 | Enabled | |

```bash
aws cloudfront create-distribution-with-tags \
  --distribution-config-with-tags file://.build/distribution.json
```

**Console:** CloudFront → Create distribution → Origin domain: pick the bucket → Origin access: **Origin access control settings** and select the OAC → Viewer protocol policy **Redirect HTTP to HTTPS** → Cache policy **CachingOptimized** → Response headers policy **SecurityHeadersPolicy** → Default root object `index.html` → Create. Then open **Error pages** and add the 403 and 404 custom responses.

## Step 4: Let only this distribution read the bucket

The bucket policy grants `s3:GetObject` to the CloudFront service, and only when the request comes from this one distribution (`AWS:SourceArn`).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<bucket>/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>"
        }
      }
    }
  ]
}
```

```bash
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://.build/bucket-policy.json
```

**Console:** after creating the distribution, CloudFront shows a banner with **Copy policy**. Paste it into S3 → bucket → Permissions → Bucket policy.

## Step 5: Upload the site

[`scripts/deploy.sh`](../scripts/deploy.sh) uploads every file in `site/` with an explicit `Content-Type` and `Cache-Control`:

| Files | Content-Type | Cache-Control |
|---|---|---|
| `*.html` | `text/html; charset=utf-8` | `no-cache` (browsers revalidate every time) |
| `*.css` | `text/css; charset=utf-8` | `public, max-age=300` |
| `*.js` | `application/javascript; charset=utf-8` | `public, max-age=300` |
| `*.svg` | `image/svg+xml` | `public, max-age=300` |

The content types are set explicitly because guessing them from the local operating system can give wrong results on Windows. The script also writes a `build.js` that records the Git commit and time, which the live page shows under **Build**.

## Step 6: Wait for the distribution to deploy

```bash
aws cloudfront wait distribution-deployed --id <distribution-id>
```

This usually takes 3 to 10 minutes while the configuration reaches every edge location. The site is then live at `https://<id>.cloudfront.net`.

## Updating the site

Edit files in `site/`, commit, and run:

```bash
./scripts/deploy.sh
```

The script uploads the changed files, deletes objects that were removed locally, and creates a CloudFront invalidation for `/*` so edge locations fetch the new files straight away.

## Verifying

```bash
./scripts/verify.sh
```

It checks HTTPS, the HTTP to HTTPS redirect, content types, the custom 404 page, the security headers, that CloudFront served the response, and that direct S3 access is denied. The results from this deployment are in the [README](../README.md#verification).

## Removing everything

```bash
./scripts/teardown.sh
```

The script disables and then deletes the distribution, deletes the OAC, removes every object version, and deletes the bucket.
