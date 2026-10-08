# GCP plan G1: HTTPS in front of the API, so the Firebase-hosted UI (HTTPS only)
# can call it without the browser blocking "mixed content".

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled" # GraphQL answers are per-request POSTs: never cache them
}

# Forward every viewer header (Origin, Access-Control-Request-*) and query string to the API,
# except Host: CloudFront sends the ALB's own name instead, the one origins expect.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "api" {
  enabled     = true
  comment     = "${var.name} api"
  price_class = "PriceClass_100"

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.app.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # the ALB has no certificate; HTTPS ends at CloudFront
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"] # POST + OPTIONS preflight need the full set
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true
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
