# Application Load Balancer in front of the Airflow API server (port 8080).

resource "aws_lb" "airflow" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = var.alb_internal
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_subnet_ids
  idle_timeout       = 120
}

resource "aws_lb_target_group" "airflow" {
  name     = "${var.name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/api/v2/monitor/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_target_group_attachment" "airflow" {
  target_group_arn = aws_lb_target_group.airflow.arn
  target_id        = aws_instance.airflow.id
  port             = 8080
}

# HTTP: forwards to Airflow, or redirects to HTTPS when a certificate is set.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.airflow.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.airflow.arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https ? 1 : 0

  load_balancer_arn = aws_lb.airflow.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.airflow.arn
  }
}

# Optional friendly URL.
resource "aws_route53_record" "airflow" {
  count = var.route53_zone_id != null && var.hostname != null ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.airflow.dns_name
    zone_id                = aws_lb.airflow.zone_id
    evaluate_target_health = false
  }
}
