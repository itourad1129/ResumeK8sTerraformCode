variable "enable_manifest_output" {
  type        = bool
  default     = false
  description = "The flag to enable to display all of data.helm_template resources."
}

variable "agones_version" {
  type        = string
  default     = "1.33.0"
  description = "The version of Agones."
}

locals {
  agones_github_branch = "release-${var.agones_version}"
}
