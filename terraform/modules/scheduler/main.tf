resource "aws_scheduler_schedule" "scheduler" {
  name       = var.name
  group_name = var.group_name

  flexible_time_window {
    mode = var.flexible_time_window
    maximum_window_in_minutes = var.flexible_time_window == "OFF" ? null : var.maximum_window_in_minutes
  }

  schedule_expression = var.schedule_expression

  target {
    arn      = var.target_arn
    role_arn = var.role_arn
  }
}