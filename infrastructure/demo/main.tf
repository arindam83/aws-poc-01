terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # Store state in S3 (create this bucket first)
 backend "s3" {
  bucket = "arindam83-terraform-state-poc"
  key    = "demo/terraform.tfstate"
  region = "us-east-1"
}
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  default     = "dev"
}

# Example 1: S3 bucket for static website
resource "aws_s3_bucket" "demo_website" {
  bucket = "demo-website-${var.environment}-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Demo Website"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_website_configuration" "demo_website" {
  bucket = aws_s3_bucket.demo_website.id
  
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "demo_website" {
  bucket = aws_s3_bucket.demo_website.id
  
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "demo_website" {
  bucket = aws_s3_bucket.demo_website.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.demo_website.arn}/*"
      }
    ]
  })
}

# Example 2: DynamoDB table
resource "aws_dynamodb_table" "demo_table" {
  name           = "demo-${var.environment}-users"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "userId"
  
  attribute {
    name = "userId"
    type = "S"
  }
  
  tags = {
    Name        = "Demo Users Table"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Example 3: Lambda function
resource "aws_iam_role" "lambda_role" {
  name = "demo-lambda-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

resource "aws_lambda_function" "demo_function" {
  filename      = "lambda.zip"
  function_name = "demo-function-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  
  source_code_hash = filebase64sha256("lambda.zip")
  
  environment {
    variables = {
      ENVIRONMENT = var.environment
      TABLE_NAME  = aws_dynamodb_table.demo_table.name
    }
  }
  
  tags = {
    Name        = "Demo Function"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Get current account ID
data "aws_caller_identity" "current" {}

# Outputs
output "website_endpoint" {
  value       = aws_s3_bucket_website_configuration.demo_website.website_endpoint
  description = "Website endpoint URL"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.demo_table.name
  description = "DynamoDB table name"
}

output "lambda_function_name" {
  value       = aws_lambda_function.demo_function.function_name
  description = "Lambda function name"
}