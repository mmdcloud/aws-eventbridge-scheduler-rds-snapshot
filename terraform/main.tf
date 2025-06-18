# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "db-backup-lambda-role"

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

# IAM Policy for Lambda
resource "aws_iam_policy" "lambda_policy" {
  name        = "db-backup-lambda-policy"
  description = "Policy for DB backup Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds:CreateDBSnapshot",
          "rds:DescribeDBSnapshots",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach Policy to Role
resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Lambda Function
resource "aws_lambda_function" "db_backup" {
  filename      = "db_backup_lambda.zip"
  function_name = "daily-db-backup"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  timeout       = 30

  environment {
    variables = {
      DB_INSTANCE_IDENTIFIER = "prod-database"
    }
  }
}

# Lambda Function Code (would be in a separate file, zipped)
# This is just for illustration - you'd create this file separately
# File: index.py
"""
import boto3
import os

def handler(event, context):
    rds = boto3.client('rds')
    db_instance = os.environ['DB_INSTANCE_IDENTIFIER']
    snapshot_id = f"{db_instance}-snapshot-{datetime.datetime.now().strftime('%Y-%m-%d-%H-%M')}"
    
    response = rds.create_db_snapshot(
        DBSnapshotIdentifier=snapshot_id,
        DBInstanceIdentifier=db_instance
    )
    
    return {
        'statusCode': 200,
        'body': f"Started snapshot {snapshot_id}"
    }
"""

# EventBridge Scheduler IAM Role
resource "aws_iam_role" "scheduler_role" {
  name = "eventbridge-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

# Scheduler Policy
resource "aws_iam_policy" "scheduler_policy" {
  name        = "eventbridge-scheduler-policy"
  description = "Policy for EventBridge Scheduler to invoke Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.db_backup.arn
      }
    ]
  })
}

# Attach Policy to Scheduler Role
resource "aws_iam_role_policy_attachment" "scheduler_attach" {
  role       = aws_iam_role.scheduler_role.name
  policy_arn = aws_iam_policy.scheduler_policy.arn
}

# EventBridge Scheduler
resource "aws_scheduler_schedule" "daily_db_backup" {
  name       = "daily-db-backup-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "cron(0 2 * * ? *)" # 2 AM daily

  target {
    arn      = aws_lambda_function.db_backup.arn
    role_arn = aws_iam_role.scheduler_role.arn
  }

  # Optional retry policy
  retry_policy {
    maximum_event_age_in_seconds = 86400 # 24 hours
    maximum_retry_attempts      = 3
  }
}

# Lambda Permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.db_backup.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.daily_db_backup.arn
}