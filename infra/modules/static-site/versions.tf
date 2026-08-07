terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      # Both aliases are supplied by the calling environment root. The module
      # declares no provider blocks of its own so it stays composable and can
      # be destroyed cleanly.
      #   aws.this      — region the environment's resources live in
      #   aws.us_east_1 — required for the CloudFront viewer certificate
      configuration_aliases = [
        aws.this,
        aws.us_east_1,
      ]
    }

    # Used by the time_sleep resources that gate on IAM policy propagation.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
