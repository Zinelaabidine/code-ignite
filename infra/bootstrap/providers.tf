provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource this root creates, so individual
  # resources only declare their own `Name`.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform/bootstrap"
    }
  }
}
