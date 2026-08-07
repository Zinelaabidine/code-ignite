terraform {
  # `use_lockfile = true` in the S3 backend requires 1.10 or newer. Pinning the
  # lower bound stops a developer on an older CLI from getting an opaque
  # "Unsupported argument" error inside the backend block.
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
