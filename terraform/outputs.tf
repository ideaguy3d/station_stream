output "url" {
  description = "Open this in a browser."
  value       = "http://${aws_lb.app.dns_name}/?station=north"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.video.domain_name
}

output "ecr_repository_url" {
  description = "Push the image here before the service can start."
  value       = aws_ecr_repository.app.repository_url
}
