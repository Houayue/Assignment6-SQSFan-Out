provider "aws" {
  region = "us-east-1"
}


resource "aws_s3_bucket" "input_bucket" {
  bucket = "image-upload-bucket"
  force_destroy = true
}


resource "aws_s3_bucket" "output_bucket" {
  bucket = "image-output-bucket"
  force_destroy = true
}


resource "aws_sns_topic" "image_topic" {
  name = "image-upload-topic"
}


resource "aws_s3_bucket_notification" "s3_event" {
  bucket = aws_s3_bucket.input_bucket.id

  topic {
    topic_arn = aws_sns_topic.image_topic.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sns_topic.image_topic]
}


resource "aws_sqs_queue" "processing_queue" {
  name = "image-processing-queue"
}


resource "aws_sqs_queue_policy" "allow_sns_publish" {
  queue_url = aws_sqs_queue.processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = "*",
      Action = "SQS:SendMessage",
      Resource = aws_sqs_queue.processing_queue.arn,
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.image_topic.arn
        }
      }
    }]
  })
}


resource "aws_sns_topic_subscription" "sns_to_sqs" {
  topic_arn = aws_sns_topic.image_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.processing_queue.arn
}


resource "aws_iam_role" "lambda_exec" {
  name = "lambda_execution_role"

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


resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        Resource = [
          "${aws_s3_bucket.input_bucket.arn}/*",
          "${aws_s3_bucket.output_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = "sqs:ReceiveMessage",
        Resource = aws_sqs_queue.processing_queue.arn
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}


resource "aws_lambda_function" "image_processor" {
  filename      = "lambda.zip"
  function_name = "ImageProcessor"
  runtime       = "python3.8"
  handler       = "handler.main"
  role          = aws_iam_role.lambda_exec.arn

  environment {
    variables = {
      OUTPUT_BUCKET = aws_s3_bucket.output_bucket.bucket
    }
  }
}


resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.processing_queue.arn
  function_name    = aws_lambda_function.image_processor.function_name
  batch_size       = 1
}