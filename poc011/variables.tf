variable "region" { default = "us-east-1" }
variable "repo" { description = "github repo owner/name e.g. arindam83/aws-poc-01" }
variable "github_secret_name" { description = "Secrets Manager secret name containing {\"token\":\"...\"}" }
variable "ami_id" { description = "AMI id (Amazon Linux 2 recommended)" }
variable "instance_type" { default = "t3.small" }
variable "asg_max" { default = 2 }
variable "asg_name" { default = "gh-runner-asg-poc" }
variable "admin_ipv4" { default = "" } # optional SSH CIDR, set "203.0.113.4/32" if you want SSH
variable "runner_version" { default = "2.319.0" }
variable "asg_desired" {
  description = "Desired capacity for ASG"
  type        = number
  default     = 0
}