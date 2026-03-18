terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "devops-accelerator-platform-tf-state-abhay"
    key            = "global/devops-accelerator/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "devops-accelerator-tf-locker"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------
# RANDOM ID (for unique buckets)
# -----------------------------
resource "random_id" "bucket_id" {
  byte_length = 4
}

# -----------------------------
# IAM roles for Lambda
# -----------------------------

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# -----------------------------
# Upload Bucket
# -----------------------------

resource "aws_s3_bucket" "upload_bucket" {
  bucket        = "upload-bucket-${random_id.bucket_id.hex}"
  force_destroy = true
}

# -----------------------------
# Lambda: Process Uploaded File
# -----------------------------

resource "aws_lambda_function" "process_uploaded_file" {
  function_name = "process-uploaded-file"
  runtime       = "python3.11"
  handler       = "main.lambda_handler"
  filename      = "${path.module}/../../backend/process-uploaded-file/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../../backend/process-uploaded-file/lambda.zip")
  role = aws_iam_role.lambda_exec_role.arn

  environment {
    variables = {
      UPLOAD_BUCKET = aws_s3_bucket.upload_bucket.bucket
      SNS_TOPIC_ARN = aws_sns_topic.devops_accelerator_upload_notify.arn
    }
  }
}

resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.upload_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_uploaded_file.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_uploaded_file.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.upload_bucket.arn
}

# -----------------------------
# Frontend Hosting
# -----------------------------

resource "aws_s3_bucket" "frontend_bucket" {
  bucket        = "frontend-bucket-${random_id.bucket_id.hex}"
  force_destroy = true

  tags = {
    Name = "Frontend Hosting Bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend_bucket_public_access" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend_bucket_website" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_policy" "frontend_bucket_policy" {
  bucket = aws_s3_bucket.frontend_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadGetObject",
      Effect    = "Allow",
      Principal = "*",
      Action    = "s3:GetObject",
      Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend_bucket_public_access]
}

# -----------------------------
# Presign Lambda
# -----------------------------

resource "aws_iam_role" "presign_lambda_role" {
  name = "DevOps-Accelerator-Presign-Lambda-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "presign_lambda_policy" {
  name = "DevOps-Accelerator-Presign-Lambda-Policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.upload_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "presign_lambda_attach" {
  role       = aws_iam_role.presign_lambda_role.name
  policy_arn = aws_iam_policy.presign_lambda_policy.arn
}

resource "aws_lambda_function" "presign_lambda" {
  function_name = "DevOps-Accelerator-Presign-Handler"
  role          = aws_iam_role.presign_lambda_role.arn
  handler       = "main.lambda_handler"
  runtime       = "python3.12"

  filename      = "${path.module}/../../backend/generate-presigned-url/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../../backend/generate-presigned-url/lambda.zip")

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.upload_bucket.bucket
    }
  }
}