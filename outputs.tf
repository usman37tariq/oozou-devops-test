output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.ecs_cluster.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.ecs_service.name
}

output "load_balancer_dns" {
  description = "DNS name of the application load balancer"
  value       = aws_lb.application_lb.dns_name
}
