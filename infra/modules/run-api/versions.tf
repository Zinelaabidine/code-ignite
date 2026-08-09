terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      # Supplied by the calling environment root. This module creates no
      # CloudFront resources of its own (the static-site module owns the
      # distribution and its behaviors) — only the region the Lambda and
      # Lambda-type OAC live in.
      configuration_aliases = [
        aws.this,
      ]
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
