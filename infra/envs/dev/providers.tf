provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource in this environment. Resources still
  # declare their own `Name`; the other three mandatory tags come from here so
  # they cannot be forgotten on a new resource.
  default_tags {
    tags = {
      Environment = "dev"
      Project     = var.project_name
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront viewer certificates and CLOUDFRONT-scoped WAF web ACLs must be
# created in us-east-1 no matter where the rest of the stack lives.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "dev"
      Project     = var.project_name
      ManagedBy   = "terraform"
    }
  }
}
