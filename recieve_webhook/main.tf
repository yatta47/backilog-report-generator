terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "random" {}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-northeast-1"
}

#-------------------------------------------------------------------------------
# S3 バケット（Webhooks 保存先）
#-------------------------------------------------------------------------------
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "backlog_webhook" {
  bucket        = "backlog-webhook-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

# ------------------------------------------------
# ライフサイクルを専用リソースで定義
# ------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "backlog_webhook" {
  bucket = aws_s3_bucket.backlog_webhook.id

  rule {
    id     = "expire-objects-after-365-days"
    status = "Enabled"

    expiration {
      days = 365
    }
  }

  # もし中途半端なマルチパートアップロードの中止も設定したければ
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ------------------------------------------------
# パブリックアクセス禁止設定
# ------------------------------------------------
resource "aws_s3_bucket_public_access_block" "backlog_webhook" {
  bucket                  = aws_s3_bucket.backlog_webhook.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------
# バケットポリシー：Lambda ロールからの PutObject のみ許可
# ------------------------------------------------
data "aws_iam_policy_document" "s3_only_lambda_put" {
  statement {
    sid    = "AllowOnlyLambdaPut"
    effect = "Allow"

    # Lambda 実行ロール ARN を指定
    principals {
      type        = "AWS"
      identifiers = [ aws_iam_role.lambda_exec_role.arn ]
    }

    actions   = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.backlog_webhook.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "backlog_webhook" {
  bucket = aws_s3_bucket.backlog_webhook.id
  policy = data.aws_iam_policy_document.s3_only_lambda_put.json
}

#-------------------------------------------------------------------------------
# Lambda 実行用 IAM ロールとポリシー
#-------------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "backlog-webhook-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.backlog_webhook.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "backlog-webhook-lambda-policy"
  role   = aws_iam_role.lambda_exec_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

#-------------------------------------------------------------------------------
# Lambda ファンクションのパッケージング
#-------------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda/lambda.zip"
}

#-------------------------------------------------------------------------------
# Lambda ファンクション
#-------------------------------------------------------------------------------
resource "aws_lambda_function" "webhook_handler" {
  function_name = "backlog_webhook_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_function.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.backlog_webhook.bucket
    }
  }

  # 任意でタイムアウトやメモリ調整
  timeout = 10
  memory_size = 128
}

#-------------------------------------------------------------------------------
# API Gateway v2 (HTTP API) の定義
#-------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "backlog-webhook-api"
  protocol_type = "HTTP"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webhook_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_webhook" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

#-------------------------------------------------------------------------------
# 出力：Webhook URL
#-------------------------------------------------------------------------------
output "webhook_url" {
  description = "Backlog Webhook で設定する HTTP エンドポイント URL"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/webhook"
}

