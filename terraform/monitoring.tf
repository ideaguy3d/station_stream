# Phase 7: alert topic, email, four alarms, autoscaling.

resource "aws_sns_topic" "alerts" {
  name         = "${var.name}-alerts"
  display_name = "StationTF"
}

# Terraform creates it, but YOU still click the confirmation email.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  lb_dim = { LoadBalancer = aws_lb.app.arn_suffix }
  tg_dim = { LoadBalancer = aws_lb.app.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }

  # One map, four alarms: the repetitive part the console made us do by hand.
  alarms = {
    no-healthy-targets = {
      description = "OUTAGE: zero healthy API tasks, viewers get 503s. Look: ECS > ${var.name} > api > Events, then Logs."
      metric      = "HealthyHostCount", stat = "Minimum", op = "LessThanThreshold", periods = 1
      missing     = "breaching", dims = local.tg_dim
    }
    unhealthy-targets = {
      description = "A task is failing /health. Look: ECS > api > Tasks, then Logs."
      metric      = "UnHealthyHostCount", stat = "Maximum", op = "GreaterThanOrEqualToThreshold", periods = 2
      missing     = "notBreaching", dims = local.tg_dim
    }
    target-5xx = {
      description = "The API itself returned 5xx. Look: CloudWatch Logs /ecs/${var.name}."
      metric      = "HTTPCode_Target_5XX_Count", stat = "Sum", op = "GreaterThanOrEqualToThreshold", periods = 1
      missing     = "notBreaching", dims = local.lb_dim
    }
    elb-5xx = {
      description = "The load balancer returned 5xx (503 = no healthy targets)."
      metric      = "HTTPCode_ELB_5XX_Count", stat = "Sum", op = "GreaterThanOrEqualToThreshold", periods = 1
      missing     = "notBreaching", dims = local.lb_dim
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  statistic           = each.value.stat
  period              = 60
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = 1
  comparison_operator = each.value.op
  treat_missing_data  = each.value.missing
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Autoscaling (tuned in L2 after the spike test): 1 to var.api_max_tasks tasks, two target-tracking
# policies. AWS scales OUT when either policy asks and IN only when both agree.
variable "api_max_tasks" {
  description = "Autoscaling ceiling. Also a cost cap: each 0.25 vCPU ARM task is about $0.01/hour."
  type        = number
  default     = 6
}

variable "api_requests_per_task_target" {
  description = "ALB requests per task per minute to aim for. L2 run 2: one task served ~17,800/min at ~65% CPU, so 15,000 (~250 req/s, ~55% CPU) leaves headroom."
  type        = number
  default     = 15000
}

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.app.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = var.api_max_tasks
}

resource "aws_appautoscaling_policy" "cpu60" {
  name               = "cpu60"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300 # slow in: don't flap after a spike
    scale_out_cooldown = 60  # fast out: was 300, which left a spike under-served for 5+ minutes
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Scale on traffic itself, not on its side effect (CPU). Requests per task rise the moment viewers
# arrive; CPU follows and, on a saturated task, stops telling you how far over capacity you are.
resource "aws_appautoscaling_policy" "requests_per_task" {
  name               = "requests-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.api_requests_per_task_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # "app/<alb>/<id>/targetgroup/<tg>/<id>": which load balancer + target group to count
      resource_label = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
