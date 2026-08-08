terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      # Supplied by the calling environment root. Unlike static-site, this
      # module never touches CloudFront, so it needs only the region the
      # queue and bucket live in — no us_east_1 alias.
      configuration_aliases = [
        aws.this,
      ]
    }

    # Used by the time_sleep resource that gates on IAM policy propagation.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
