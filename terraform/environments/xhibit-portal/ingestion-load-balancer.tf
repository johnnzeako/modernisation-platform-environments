resource "aws_security_group" "ingestion_lb" {
  description = "Security group for ingestion load balancer, to do server certificate auth with Xhibit"
  name        = "ingestion-loadbalancer-${var.networking[0].application}"
  vpc_id      = local.vpc_id
}

resource "aws_security_group_rule" "egress-to-ingestion" {
  depends_on               = [aws_security_group.ingestion_lb]
  security_group_id        = aws_security_group.ingestion_lb.id
  type                     = "egress"
  description              = "allow web traffic to get to ingestion server"
  from_port                = 80
  to_port                  = 80
  protocol                 = "TCP"
  source_security_group_id = aws_security_group.cjip-server.id
}

resource "aws_security_group_rule" "ingestion_lb_allow_web_users" {
  depends_on        = [aws_security_group.ingestion_lb]
  security_group_id = aws_security_group.ingestion_lb.id
  type              = "ingress"
  description       = "allow web traffic to get to ingestion server"
  from_port         = 443
  to_port           = 443
  protocol          = "TCP"
  cidr_blocks = [
    "109.152.47.104/32", # George
    "81.101.176.47/32",  # Aman
    "77.100.255.142/32", # Gary 77.100.255.142
    "20.49.163.173/32",  # Azure function proxy
    "20.49.163.191/32",  # Azure function proxy
    "20.49.163.194/32",  # Azure function proxy
    "20.49.163.244/32",  # Azure function proxy
    "82.44.118.20/32",   # Nick
    "10.175.52.4/32",    # Anthony Fletcher
    "10.182.60.51/32",   # NLE CGI proxy 
    "10.175.165.159/32", # Helen Dawes
    "10.175.72.157/32",  # Alan Brightmore
    "5.148.32.215/32",   # NCC Group proxy ITHC
    "195.95.131.110/32", # NCC Group proxy ITHC
    "195.95.131.112/32", # NCC Group proxy ITHC
    "81.152.37.83/32",   # Anand
    "77.108.144.130/32", # AL Office
    "194.33.196.1/32",   # ATOS PROXY IPS
    "194.33.196.2/32",   # ATOS PROXY IPS
    "194.33.196.3/32",   # ATOS PROXY IPS
    "194.33.196.4/32",   # ATOS PROXY IPS
    "194.33.196.5/32",   # ATOS PROXY IPS
    "194.33.196.6/32",   # ATOS PROXY IPS
    "194.33.196.46/32",  # ATOS PROXY IPS
    "194.33.196.47/32",  # ATOS PROXY IPS
    "194.33.196.48/32",  # ATOS PROXY IPS
    "194.33.192.1/32",   # ATOS PROXY IPS
    "194.33.192.2/32",   # ATOS PROXY IPS
    "194.33.192.3/32",   # ATOS PROXY IPS
    "194.33.192.4/32",   # ATOS PROXY IPS
    "194.33.192.5/32",   # ATOS PROXY IPS
    "194.33.192.6/32",   # ATOS PROXY IPS
    "194.33.192.46/32",  # ATOS PROXY IPS
    "194.33.192.47/32",  # ATOS PROXY IPS
    "194.33.192.48/32",  # ATOS PROXY IPS
    "195.59.75.151/32",  # New proxy IPs from Prashanth for testing ingestion
    "195.59.75.152/32",  # New proxy IPs from Prashanth for testing ingestion
    "109.146.174.114/32",   # Prashanth
  ]
  ipv6_cidr_blocks = [
    "2a00:23c7:2416:3d01:c98d:4432:3c83:d937/128"
  ]
}

data "aws_subnet_ids" "ingestion-shared-public" {
  vpc_id = local.vpc_id
  tags = {
    "Name" = "${var.networking[0].business-unit}-${local.environment}-${var.networking[0].set}-public*"
  }
}

resource "aws_elb" "ingestion_lb" {

  depends_on = [
    aws_security_group.ingestion_lb,
  ]

  name                       = "ingestion-lb-${var.networking[0].application}"
  internal                   = false
  security_groups            = [aws_security_group.ingestion_lb.id]
  subnets                    = data.aws_subnet_ids.ingestion-shared-public.ids

  access_logs {
    bucket  = aws_s3_bucket.loadbalancer_logs.bucket
    bucket_prefix  = "http-lb"
    enabled = true
  }

  listener {
    instance_port      = 80
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.ingestion_lb_cert.arn
  }

  health_check {
    healthy_threshold   = 6
    unhealthy_threshold = 2
    timeout             = 2
    target              = "HTTP:80/"
    interval            = 5
  }

  instances                   = [aws_instance.cjip-server.id]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = merge(
    local.tags,
    {
      Name = "ingestion-lb-${var.networking[0].application}"
    },
  )
}

data "aws_acm_certificate" "ingestion_cert" {
  domain   = local.application_data.accounts[local.environment].public_dns_name_ingestion
  statuses = ["ISSUED"]
}

resource "aws_acm_certificate_validation" "ingestion_lb_cert_validation" {
  certificate_arn = aws_acm_certificate.ingestion_lb_cert.arn
  //validation_record_fqdns = [for record in aws_route53_record.ingestion_lb_r53_record : record.fqdn]
  validation_record_fqdns = [for dvo in aws_acm_certificate.ingestion_lb_cert.domain_validation_options : dvo.resource_record_name]
}

resource "aws_s3_bucket" "ingestion_loadbalancer_logs" {
  bucket        = "${var.networking[0].application}.${var.networking[0].business-unit}-${local.environment}-ingestion-lblogs"
  acl           = "log-delivery-write"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "ingestion_loadbalancer_logs_policy" {
  bucket = aws_s3_bucket.ingestion_loadbalancer_logs.bucket
  policy = data.aws_iam_policy_document.s3_bucket_lb_write.json
}


data "aws_iam_policy_document" "s3_bucket_ingestion_lb_write" {

  statement {
    actions = [
      "s3:PutObject",
    ]
    effect = "Allow"
    resources = [
      "${aws_s3_bucket.ingestion_loadbalancer_logs.arn}/*",
    ]

    principals {
      identifiers = ["arn:aws:iam::652711504416:root"]
      type        = "AWS"
    }
  }

  statement {
    actions = [
      "s3:PutObject"
    ]
    effect    = "Allow"
    resources = ["${aws_s3_bucket.ingestion_loadbalancer_logs.arn}/*"]
    principals {
      identifiers = ["delivery.logs.amazonaws.com"]
      type        = "Service"
    }
  }

  statement {
    actions = [
      "s3:GetBucketAcl"
    ]
    effect    = "Allow"
    resources = ["${aws_s3_bucket.ingestion_loadbalancer_logs.arn}"]
    principals {
      identifiers = ["delivery.logs.amazonaws.com"]
      type        = "Service"
    }
  }
}