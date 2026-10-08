# Phase 5.1 / 5.2: reuse the default VPC, two public subnets, two chained firewalls.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "a" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.region}a"
  default_for_az    = true
}

data "aws_subnet" "b" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.region}b"
  default_for_az    = true
}

locals {
  subnet_ids = [data.aws_subnet.a.id, data.aws_subnet.b.id]
}

# Load balancer firewall: port 80 from anywhere.
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public HTTP to the load balancer"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_out" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Task firewall: port 4000 only from the load balancer's group (not an IP range).
resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Only the load balancer may reach the API task"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "API port from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 4000
  to_port                      = 4000
  ip_protocol                  = "tcp"
}

# Outbound: the task must reach ECR (pull image) and CloudWatch (logs).
# The console added this rule silently; Terraform makes you write it.
resource "aws_vpc_security_group_egress_rule" "task_out" {
  security_group_id = aws_security_group.task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
