# Phase 6: private S3 bucket + CloudFront with Origin Access Control + the video files.

resource "aws_s3_bucket" "video" {
  bucket        = "${var.name}-video-${data.aws_caller_identity.me.account_id}"
  force_destroy = true # lets "terraform destroy" empty it first
}

resource "aws_s3_bucket_public_access_block" "video" {
  bucket                  = aws_s3_bucket.video.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "video" {
  bucket = aws_s3_bucket.video.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

# Upload every playlist, segment and poster, each with the right Content-Type and cache time.
locals {
  video_files = setunion(
    fileset(var.video_dir, "**/*.m3u8"),
    fileset(var.video_dir, "**/*.ts"),
    fileset(var.video_dir, "**/*.jpg"),
  )
  content_type = {
    m3u8 = "application/vnd.apple.mpegurl"
    ts   = "video/mp2t" # NOT TypeScript
    jpg  = "image/jpeg"
  }
  cache_control = {
    m3u8 = "public,max-age=300"
    ts   = "public,max-age=31536000,immutable"
    jpg  = "public,max-age=86400"
  }
}

resource "aws_s3_object" "video" {
  for_each = local.video_files

  bucket        = aws_s3_bucket.video.id
  key           = each.value
  source        = "${var.video_dir}/${each.value}"
  source_hash   = filemd5("${var.video_dir}/${each.value}") # re-upload only if the file changed
  content_type  = local.content_type[regex("[^.]+$", each.value)]
  cache_control = local.cache_control[regex("[^.]+$", each.value)]
}

# CloudFront signs every request to S3 with this.
resource "aws_cloudfront_origin_access_control" "video" {
  name                              = "${var.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed policies, looked up by name (same ones picked in the console).
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "cors" {
  name = "Managed-CORS-With-Preflight"
}

resource "aws_cloudfront_distribution" "video" {
  enabled     = true
  comment     = "${var.name} video"
  price_class = "PriceClass_100" # North America + Europe edges only (app 1 defaulted to All)

  origin {
    origin_id                = "s3-video"
    domain_name              = aws_s3_bucket.video.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.video.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-video"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.cors.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # free *.cloudfront.net HTTPS
  }
}

# Only THIS distribution may read objects (the policy the console wrote for us in app 1).
data "aws_iam_policy_document" "video_bucket" {
  statement {
    sid       = "AllowCloudFrontServicePrincipal"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.video.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.video.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "video" {
  bucket = aws_s3_bucket.video.id
  policy = data.aws_iam_policy_document.video_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.video]
}
