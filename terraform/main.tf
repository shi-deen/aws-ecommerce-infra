terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

####################
# Variables
####################
variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ssh_key_name" {
  type    = string
  default = "" # set your key if you want SSH access
}

variable "alb_certificate_arn" {
  type    = string
  default = "arn:aws:acm:us-east-1:058264439124:certificate/cc8138f3-0c09-4e12-aed2-9c22a4b0de68" # ACM certificate ARN for the ALB (required if you want HTTPS with a proper cert). If empty, ALB listener will still accept HTTPS but you should provide a cert.
}

####################
# Data sources
####################
data "aws_availability_zones" "available" {
  state = "available"
}

# CloudFront origin-facing prefix list (global). Confirm in your account/region if different.
# This is a commonly used global PL id; validate before production.
locals {
  cloudfront_origin_prefix_list_id = "pl-82a045eb"
}

####################
# VPC & Subnets
####################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "ecomm-vpc"
  }
}

# Public subnets
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "ecomm-public-${count.index + 1}"
    AZ   = data.aws_availability_zones.available.names[count.index]
  }
}

# Private app subnets
resource "aws_subnet" "private_app" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "ecomm-private-app-${count.index + 1}"
  }
}

# Private DB subnets
resource "aws_subnet" "private_db" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "ecomm-private-db-${count.index + 1}"
  }
}

####################
# Internet Gateway + Public route table
####################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "ecomm-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "ecomm-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

####################
# NAT Gateways (EIP per NAT) - one per public subnet/AZ
####################
resource "aws_eip" "nat_eip" {
  count = 3
  vpc   = true

  tags = {
    Name = "ecomm-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "nat" {
  count         = 3
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw]

  tags = {
    Name = "ecomm-nat-${count.index + 1}"
  }
}

####################
# Private route tables (one per AZ) -> route 0.0.0.0/0 to NAT in same AZ
####################
resource "aws_route_table" "private_app" {
  count  = 3
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "ecomm-private-app-rt-${count.index + 1}"
  }
}

resource "aws_route" "private_default" {
  count                  = 3
  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[count.index].id
}

resource "aws_route_table_association" "private_app_assoc" {
  count          = 3
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Optional DB private route tables (no NAT; isolated)
resource "aws_route_table" "private_db" {
  count  = 3
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "ecomm-private-db-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private_db_assoc" {
  count          = 3
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db[count.index].id
}

####################
# Security Groups
####################
# ALB SG - allow HTTPS from CloudFront prefix list only
resource "aws_security_group" "alb" {
  name        = "ecomm-alb-sg"
  description = "Allow HTTPS from CloudFront only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description      = "Allow HTTPS from CloudFront"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    prefix_list_ids  = [local.cloudfront_origin_prefix_list_id]
  }

  # (Optional) If you expect direct access from your office, add additional ingress rules here.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecomm-alb-sg"
  }
}

# App instances SG - allow HTTP only from ALB SG
resource "aws_security_group" "app" {
  name        = "ecomm-app-sg"
  description = "Allow HTTP from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Allow HTTP from ALB"
  }

  # Allow SSH from your IP if a key is supplied (optional)
  dynamic "ingress" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"] # replace with your office IP for security
      description = "SSH (replace with your admin IP)"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecomm-app-sg"
  }
}

####################
# ALB, Target Group, Listeners
####################
resource "aws_lb" "alb" {
  name               = "ecomm-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = {
    Name = "ecomm-alb"
  }
}

resource "aws_lb_target_group" "tg" {
  name     = "ecomm-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }

  tags = {
    Name = "ecomm-tg"
  }
}

# HTTPS listener: requires certificate ARN in var.alb_certificate_arn (recommend ACM)
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"

  ssl_policy = "ELBSecurityPolicy-2016-08" # modify as needed

  certificate_arn = var.alb_certificate_arn != "" ? var.alb_certificate_arn : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }

  # If no certificate provided, Terraform will still try to create the listener; on AWS you should have an ACM cert for HTTPS.
  lifecycle {
    ignore_changes = [
      certificate_arn
    ]
  }
}

# HTTP listener that redirects to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

####################
# EC2 Instances (3) - simple example: one in each private app subnet
# In production you'd use Launch Templates + AutoScalingGroup; this is minimal & explicit.
####################
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "app" {
  count         = 3
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.private_app[count.index].id
  key_name      = var.ssh_key_name != "" ? var.ssh_key_name : null
  vpc_security_group_ids = [aws_security_group.app.id]

  associate_public_ip_address = false

  tags = {
    Name = "ecomm-app-${count.index + 1}"
  }

  # Optional: user_data bootstrap to install app; keep short here
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl enable httpd
              systemctl start httpd
              echo "Hello from ecomm app ${count.index + 1}" > /var/www/html/index.html
              EOF
}

# Register instances with target group
resource "aws_lb_target_group_attachment" "app_attach" {
  count            = length(aws_instance.app)
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.app[count.index].id
  port             = 80
}

####################
# CloudFront Distribution pointing to ALB
####################
resource "aws_cloudfront_distribution" "cf" {
  enabled = true

  origin {
    domain_name = aws_lb.alb.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  http_version = "http2"
  price_class  = "PriceClass_100"

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "ecomm-cf"
  }

  depends_on = [aws_lb_listener.https]
}

####################
# Outputs
####################
output "vpc_id" {
  value = aws_vpc.this.id
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cf.domain_name
}
