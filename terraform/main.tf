# Registering vault provider
data "vault_generic_secret" "rds" {
  path = "secret/rds"
}

module "db_credentials" {
  source                  = "./modules/secrets-manager"
  name                    = "rds_secrets"
  description             = "rds_secrets"
  recovery_window_in_days = 0
  secret_string = jsonencode({
    username = tostring(data.vault_generic_secret.rds.data["username"])
    password = tostring(data.vault_generic_secret.rds.data["password"])
  })
}

module "vpc" {
  source                = "./modules/vpc/vpc"
  vpc_name              = "vpc"
  vpc_cidr_block        = "10.0.0.0/16"
  enable_dns_hostnames  = true
  enable_dns_support    = true
  internet_gateway_name = "vpc_igw"
}

# RDS Security Group
module "rds_sg" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "rds_sg"
  ingress = [
    {
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
      description     = "any"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

# Public Subnets
module "public_subnets" {
  source = "./modules/vpc/subnets"
  name   = "public subnet"
  subnets = [
    {
      subnet = "10.0.1.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.2.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.3.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = true
}

# Private Subnets
module "private_subnets" {
  source = "./modules/vpc/subnets"
  name   = "private subnet"
  subnets = [
    {
      subnet = "10.0.6.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.5.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.4.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = false
}

# Carshub Public Route Table
module "public_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "public route table"
  subnets = module.public_subnets.subnets[*]
  routes = [
    {
      cidr_block     = "0.0.0.0/0"
      gateway_id     = module.vpc.igw_id
      nat_gateway_id = ""
    }
  ]
  vpc_id = module.vpc.vpc_id
}

# Carshub Private Route Table
module "private_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "private route table"
  subnets = module.private_subnets.subnets[*]
  routes  = []
  vpc_id  = module.vpc.vpc_id
}

module "db" {
  source                          = "./modules/rds"
  db_name                         = "source-db"
  allocated_storage               = 100
  engine                          = "mysql"
  engine_version                  = "8.0"
  instance_class                  = "db.t4g.large"
  multi_az                        = true
  username                        = tostring(data.vault_generic_secret.rds.data["username"])
  password                        = tostring(data.vault_generic_secret.rds.data["password"])
  subnet_group_name               = "rds_subnet_group"
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  backup_retention_period         = 35
  backup_window                   = "03:00-06:00"
  subnet_group_ids = [
    module.public_subnets.subnets[0].id,
    module.public_subnets.subnets[1].id,
    module.public_subnets.subnets[2].id
  ]
  vpc_security_group_ids                = [module.rds_sg.id]
  publicly_accessible                   = false
  deletion_protection                   = false
  skip_final_snapshot                   = true
  max_allocated_storage                 = 500
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  parameter_group_name                  = "db-pg"
  parameter_group_family                = "mysql8.0"
  parameters = [
    {
      name  = "max_connections"
      value = "1000"
    },
    {
      name  = "innodb_buffer_pool_size"
      value = "{DBInstanceClassMemory*3/4}"
    },
    {
      name  = "slow_query_log"
      value = "1"
    }
  ]
}

module "backup_function_code" {
  source      = "./modules/s3"
  bucket_name = "backupfunctioncodemadmax"
  objects = [
    {
      key    = "backup_function.zip"
      source = "./files/backup_function.zip"
    }
  ]
  bucket_policy = ""
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["GET"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  versioning_enabled = "Enabled"
  force_destroy      = true
}

# Lambda IAM  Role
module "lambda_role" {
  source             = "./modules/iam"
  role_name          = "lambda_function_iam_role"
  role_description   = "lambda_function_iam_role"
  policy_name        = "lambda_function_iam_policy"
  policy_description = "lambda_function_iam_policy"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "lambda.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
    EOF
  policy             = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                    "rds:CreateDBSnapshot",
                    "rds:DescribeDBSnapshots",
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ],
                "Resource": "*",
                "Effect": "Allow"
            },            
        ]
    }
    EOF
}

module "backup_function" {
  source        = "./modules/lambda"
  function_name = "rds-backup-function"
  role_arn      = module.lambda_role.arn
  permissions = [
    {
      statement_id = "AllowExecutionFromEventBridge"
      action       = "lambda:InvokeFunction"
      principal    = "scheduler.amazonaws.com"
      source_arn   = module.scheduler.arn
    }
  ]
  env_variables = {
    DB_INSTANCE_IDENTIFIER = "prod-database"
  }
  handler   = "backup_function.lambda_handler"
  runtime   = "python3.12"
  s3_bucket = module.backup_function_code.bucket
  s3_key    = "backup_function.zip"
}

# Lambda IAM  Role
module "scheduler_role" {
  source             = "./modules/iam"
  role_name          = "scheduler_iam_role"
  role_description   = "scheduler_iam_role"
  policy_name        = "scheduler_iam_policy"
  policy_description = "scheduler_iam_policy"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "scheduler.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
    EOF
  policy             = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                    "lambda:InvokeFunction"
                ],
                "Resource": "${module.backup_function.arn}",
                "Effect": "Allow"
            },            
        ]
    }
    EOF
}

# EventBridge Scheduler
module "scheduler" {
  source                    = "./modules/scheduler"
  name                      = "daily-db-backup-schedule"
  group_name                = "default"
  flexible_time_window      = "OFF"
  maximum_window_in_minutes = 0
  schedule_expression       = "cron(0 2 * * ? *)" # 2 AM daily
  target_arn                = module.backup_function.arn
  role_arn                  = module.scheduler_role.arn
}
