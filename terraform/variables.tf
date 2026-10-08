variable "name" {
  description = "Prefix for every resource. Must start with station-stream- (our IAM user may only create roles/topics with that prefix)."
  type        = string
  default     = "station-stream-tf"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image_tag" {
  description = "Which image (git commit) the service runs."
  type        = string
  default     = "461037e"
}

variable "alert_email" {
  description = "Where alarm emails go. AWS sends a confirmation link first."
  type        = string
  default     = "julius@ranklab.org"
}

variable "cors_origins" {
  description = "Web origins allowed to call /graphql from a browser (the Firebase-hosted UI)."
  type        = list(string)
  default     = ["https://station-stream-2026.web.app", "https://station-stream-2026.firebaseapp.com"]
}

variable "video_dir" {
  description = "Local folder of HLS files to upload (made by scripts/encode-all.sh)."
  type        = string
  default     = "../video/out"
}
