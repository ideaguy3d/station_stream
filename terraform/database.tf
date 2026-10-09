# L1: the catalog moves from JSON files into Aurora PostgreSQL Serverless v2.

variable "db_engine_version" {
  description = "Aurora PostgreSQL version. Must support scaling to 0 ACU (auto-pause)."
  type        = string
  default     = "16.15" # newest 16.x that lists ServerlessV2 MinCapacity 0 in: aws rds describe-db-engine-versions
}

variable "db_name" {
  description = "Not \"catalog\": that is a reserved word in Aurora PostgreSQL."
  type        = string
  default     = "stationstream"
}

variable "db_max_acu" {
  description = "Ceiling for Aurora capacity units (1 ACU is about 2 GiB RAM). Caps the bill if a load test goes wild."
  type        = number
  default     = 4
}

# --- Network: a private database in two AZs, reachable only from the API tasks ---------------

# A DB subnet group tells RDS which subnets (in at least 2 AZs) it may place the cluster in.
resource "aws_db_subnet_group" "db" {
  name       = "${var.name}-db"
  subnet_ids = local.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Postgres from the API tasks only"
  vpc_id      = data.aws_vpc.default.id
}

# Source is the TASK SECURITY GROUP, not an IP range: any task wearing that group may connect,
# wherever it runs and whatever IP it gets, and nothing else can (not even from inside the VPC).
resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from API tasks"
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# --- The cluster -------------------------------------------------------------------------------

resource "aws_rds_cluster" "db" {
  cluster_identifier = "${var.name}-db"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 is a "provisioned" cluster with db.serverless instances
  engine_version     = var.db_engine_version
  database_name      = var.db_name

  # RDS creates the admin password itself and keeps it in Secrets Manager. It never appears in
  # our code, state-file inputs, chat or git. Our API doesn't use it; only the migration task does.
  master_username             = "stationadmin"
  manage_master_user_password = true

  serverlessv2_scaling_configuration {
    min_capacity             = 0 # 0 ACU = auto-pause: compute stops, you pay storage only
    max_capacity             = var.db_max_acu
    seconds_until_auto_pause = 300 # pause after 5 minutes with no connections (the minimum allowed)
  }

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]

  storage_encrypted    = true # Serverless v2 defaults to unencrypted; always turn it on
  enable_http_endpoint = true # Data API: lets the console Query Editor run SQL without a network path

  backup_retention_period = 1 # days; the minimum
  copy_tags_to_snapshot   = true

  # Learning project: make destroy painless. A real production cluster would flip all three.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}

# The compute. One writer; a second instance in another AZ would be the reader that gives
# fast failover (we skip it to keep the bill small).
resource "aws_rds_cluster_instance" "writer" {
  identifier          = "${var.name}-db-1"
  cluster_identifier  = aws_rds_cluster.db.id
  engine              = aws_rds_cluster.db.engine
  engine_version      = aws_rds_cluster.db.engine_version
  instance_class      = "db.serverless"
  publicly_accessible = false
}

# --- The API's own database user: read-only, with a Terraform-generated password -----------------

# Lives in Terraform state (local, git-ignored) and in Secrets Manager; never printed.
# No special characters so it never needs URL-escaping.
resource "random_password" "api_reader" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "api_reader" {
  name                    = "${var.name}/db/api-reader"
  description             = "Password for the read-only Postgres role api_reader (created by the migration task)"
  recovery_window_in_days = 0 # delete immediately on destroy instead of the default 30-day hold
}

resource "aws_secretsmanager_secret_version" "api_reader" {
  secret_id     = aws_secretsmanager_secret.api_reader.id
  secret_string = jsonencode({ username = "api_reader", password = random_password.api_reader.result })
}

# --- Who may read which secret ------------------------------------------------------------------
# ECS's execution role fetches secrets at task start and injects them as env vars. The API's
# role may read ONLY the read-only user's secret; the admin secret goes to the migration role.

resource "aws_iam_role_policy" "task_exec_api_reader_secret" {
  name = "read-api-reader-secret"
  role = aws_iam_role.task_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.api_reader.arn
    }]
  })
}

resource "aws_iam_role" "migrate_exec" {
  name               = "${var.name}-migrate-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "migrate_exec" {
  role       = aws_iam_role.migrate_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "migrate_exec_secrets" {
  name = "read-db-secrets"
  role = aws_iam_role.migrate_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        aws_rds_cluster.db.master_user_secret[0].secret_arn, # admin: creates tables and the api_reader role
        aws_secretsmanager_secret.api_reader.arn,            # the password to give api_reader
      ]
    }]
  })
}

# --- The migration: a one-off task, same image, different command --------------------------------
# Run with `aws ecs run-task` (see outputs). "Migrations run as a task before the deploy."

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name}-migrate"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.migrate_exec.arn
  depends_on               = [aws_iam_role_policy.migrate_exec_secrets]

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true
    command   = ["node", "src/db/migrate.js"]
    environment = [
      { name = "PGHOST", value = aws_rds_cluster.db.endpoint },
      { name = "PGDATABASE", value = var.db_name },
      { name = "PGUSER", value = aws_rds_cluster.db.master_username },
    ]
    # "<secret ARN>:<json key>::" picks one field out of a JSON secret.
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${aws_rds_cluster.db.master_user_secret[0].secret_arn}:password::" },
      { name = "API_READER_PASSWORD", valueFrom = "${aws_secretsmanager_secret.api_reader.arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "migrate"
      }
    }
  }])
}

output "db_endpoint" {
  description = "Writer endpoint (private: only tasks in the task security group can connect)."
  value       = aws_rds_cluster.db.endpoint
}

output "migrate_command" {
  description = "Runs the schema + seed migration as a one-off Fargate task."
  value       = "aws ecs run-task --cluster ${aws_ecs_cluster.app.name} --task-definition ${aws_ecs_task_definition.migrate.family} --launch-type FARGATE --network-configuration 'awsvpcConfiguration={subnets=[${join(",", local.subnet_ids)}],securityGroups=[${aws_security_group.task.id}],assignPublicIp=ENABLED}'"
}
