# Container image repository for backend/Dockerfile.lambda. deploy.yml builds
# and pushes the image (tagged with the commit SHA); lambda.tf's
# aws_lambda_function.api then points at "${repository_url}:${var.image_tag}".
# Name matches local.ecr_repository_arn in locals.tf — that ARN is built by
# name so iam-deploy.tf can authorize CreateRepository without a cycle.
resource "aws_ecr_repository" "api" {
  provider = aws.this

  name                 = "${local.name_prefix}-run-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${local.name_prefix}-run-api"
  }
}

# Untagged layers pile up from interrupted pushes and retags; expire them
# after a week so the repo does not grow without bound. Tagged images
# (commit SHAs) are left alone — Lambda may still pin an older SHA.
resource "aws_ecr_lifecycle_policy" "api" {
  provider = aws.this

  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
