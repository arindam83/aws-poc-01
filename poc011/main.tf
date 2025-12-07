


data "aws_availability_zones" "available" {}

########################
# VPC & networking
########################
resource "aws_vpc" "poc_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "poc-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.poc_vpc.id
  tags = { Name = "poc-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.poc_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.poc_vpc.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "poc-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.poc_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "poc-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

########################
# Security Group
########################
resource "aws_security_group" "runner_sg" {
  name        = "poc-runner-sg"
  description = "Allow outbound HTTPS and SSM"
  vpc_id      = aws_vpc.poc_vpc.id

  # allow all outbound (so it can reach GitHub and SSM)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # no inbound needed for operations (we will use SSM); optional SSH below
  ingress {
    description = "Allow SSH from your IP (optional)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_ipv4 != "" ? [var.admin_ipv4] : []
    # if admin_ipv4 is empty no rule gets applied
  }

  tags = { Name = "poc-runner-sg" }
}

########################
# IAM - runner instance role/profile
########################
data "aws_caller_identity" "me" {}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner_role" {
  name               = "gh-runner-role-poc-${data.aws_caller_identity.me.account_id}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_policy" "runner_policy" {
  name = "gh-runner-policy-poc-${data.aws_caller_identity.me.account_id}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["secretsmanager:GetSecretValue"],
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.me.account_id}:secret:${var.github_secret_name}*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "ssm:StartSession",
          "ssm:SendCommand",
          "ssm:DescribeInstanceInformation"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "runner_attach" {
  role       = aws_iam_role.runner_role.name
  policy_arn = aws_iam_policy.runner_policy.arn
}

resource "aws_iam_instance_profile" "runner_profile" {
  name = "gh-runner-profile-poc-${data.aws_caller_identity.me.account_id}"
  role = aws_iam_role.runner_role.name
}

########################
# user-data rendering
########################
locals {
  user_data = templatefile("${path.module}/user-data.tpl", {
    repo        = var.repo
    region      = var.region
    secret_name = var.github_secret_name
    runner_version = var.runner_version
  })
}

########################
# Launch Template + ASG
########################
resource "aws_launch_template" "runner_lt" {
  name_prefix   = "gh-runner-poc-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.runner_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.runner_sg.id]
  }

user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "gh-runner-poc-${var.repo}"
      Repo = var.repo
    }
  }
}

resource "aws_autoscaling_group" "runner_asg" {
  name                      = var.asg_name
  max_size                  = var.asg_max
  min_size                  = 0
  desired_capacity          = 0
  vpc_zone_identifier       = aws_subnet.public[*].id
  launch_template {
    id      = aws_launch_template.runner_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "gh-runner-poc-${var.repo}"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

########################
# Outputs
########################
output "vpc_id" {
  value = aws_vpc.poc_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.public[*].id
}

output "security_group_id" {
  value = aws_security_group.runner_sg.id
}

output "launch_template_id" {
  value = aws_launch_template.runner_lt.id
}

output "asg_name" {
  value = aws_autoscaling_group.runner_asg.name
}
