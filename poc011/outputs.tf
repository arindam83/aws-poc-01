

output "public_subnet_ids" {
  description = "List of public subnet ids"
  value       = aws_subnet.public[*].id
}

output "route_table_id" {
  description = "Public route table id"
  value       = aws_route_table.public.id
}

output "internet_gateway_id" {
  description = "Internet gateway id"
  value       = aws_internet_gateway.igw.id
}

