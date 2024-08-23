# Module to set up VPC with subnets, NAT gateway, and DNS settings
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.environment}-vpc" # VPC name based on the environment
  cidr = var.vpc_cidr             # CIDR block for the VPC

  azs             = var.azs             # Availability Zones
  private_subnets = var.private_subnets # Private subnets within the VPC
  public_subnets  = var.public_subnets  # Public subnets within the VPC

  enable_nat_gateway = true # Enable NAT Gateway for outbound internet access
  single_nat_gateway = true # Use a single NAT Gateway to reduce costs

  enable_dns_support   = true # Enable DNS resolution support
  enable_dns_hostnames = true # Enable DNS hostnames in the VPC
}

# Create an ECR repository for storing Docker images
resource "aws_ecr_repository" "app_repository" {
  name = "app-repository-${var.environment}" # Repository name based on the environment
  image_scanning_configuration {
    scan_on_push = true # Enable scanning on image push for security
  }
}

# Read the application version from a file
data "local_file" "app_version" {
  filename = "${path.module}/version.txt" # Path to the version file
}

# Increment the version number for the Docker image tag
locals {
  version_parts       = split(".", data.local_file.app_version.content)                                                   # Split version into components
  incremented_version = join(".", [local.version_parts[0], local.version_parts[1], tonumber(local.version_parts[2]) + 1]) # Increment the patch version
}

# Build Docker image and tag it with the incremented version
resource "docker_image" "app_image" {
  name = "${aws_ecr_repository.app_repository.repository_url}:${local.incremented_version}" # Docker image name with version tag
  build {
    context    = path.module                 # Build context for the Docker image
    dockerfile = "${path.module}/Dockerfile" # Path to the Dockerfile
    target     = var.environment             # Build target based on the environment
  }
  triggers = {
    dockerfile_hash = filemd5("${path.module}/Dockerfile") # Rebuild if Dockerfile changes
  }
}

# Push the built Docker image to ECR
resource "docker_registry_image" "app_registry_image" {
  name = docker_image.app_image.name # Docker image name with tag
}

# IAM role for ECS task execution, allowing ECS to pull images and write to CloudWatch
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecsExecutionRole-${var.environment}" # Role name based on the environment

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com" # ECS service assumes this role
        }
      },
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # Attach execution role policy
  ]
}

# IAM role for the ECS task, granting permissions to the task containers
resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole-${var.environment}" # Role name based on the environment

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com" # ECS service assumes this role
        }
      },
    ]
  })
}

# ECS Cluster for running the application
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "ecs-cluster-${var.environment}" # Cluster name based on the environment
}

# ECS Task Definition, defining the containers and resources for the service
resource "aws_ecs_task_definition" "app_task_definition" {
  family                   = "app-task-family-${var.environment}" # Task family name
  network_mode             = "awsvpc"                             # Use VPC networking for ECS tasks
  requires_compatibilities = ["FARGATE"]                          # Fargate launch type for serverless containers
  cpu                      = var.cpu                              # CPU units allocated to the task
  memory                   = var.memory                           # Memory allocated to the task
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn  # Role for task execution
  task_role_arn            = aws_iam_role.ecs_task_role.arn       # Role for task permissions

  container_definitions = jsonencode([
    {
      name      = "nodejs-app"                                                                       # Name of the Node.js app container
      image     = "${aws_ecr_repository.app_repository.repository_url}:${local.incremented_version}" # Docker image with tag
      cpu       = 256                                                                                # CPU units for the Node.js container
      memory    = 512                                                                                # Memory for the Node.js container
      essential = true                                                                               # Essential container; task fails if this container fails
      portMappings = [
        {
          containerPort = 3000 # Port exposed by the Node.js app
          hostPort      = 3000 # Host port mapped to container port
        }
      ]
      logConfiguration = {
        logDriver = "awslogs" # Use AWS CloudWatch for logging
        options = {
          awslogs-group         = "/ecs/logs-${var.environment}"  # CloudWatch log group
          awslogs-region        = var.region                      # AWS region
          awslogs-stream-prefix = "nodejs-app-${var.environment}" # Log stream prefix based on the environment
        }
      }
    },
    {
      name      = "graphite"                           # Name of the Graphite container
      image     = "graphiteapp/graphite-statsd:latest" # Official Graphite image
      cpu       = 128                                  # CPU units for the Graphite container
      memory    = 256                                  # Memory for the Graphite container
      essential = true                                 # Essential container; task fails if this container fails
      portMappings = [
        {
          containerPort = 80 # Port exposed by Graphite web UI
          hostPort      = 80 # Host port mapped to container port
        },
        {
          containerPort = 2003 # Port exposed by Graphite for metrics
          hostPort      = 2003 # Host port mapped to container port
        }
      ]
    }
  ])

  # Ensure task definition depends on ECR repository and Docker image
  depends_on = [
    aws_ecr_repository.app_repository,
    docker_registry_image.app_registry_image
  ]
}

# CloudWatch Log Group for storing logs generated by the ECS tasks
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/logs-${var.environment}" # Log group name based on the environment
  retention_in_days = var.retention_in_days          # Number of days to retain logs

  # Ensure log group creation depends on ECS cluster creation
  depends_on = [
    aws_ecs_cluster.ecs_cluster
  ]
}

# ECS Service to run the task definition with desired scaling and networking
resource "aws_ecs_service" "ecs_service" {
  name            = "ecs-service-${var.environment}"                # Service name based on the environment
  cluster         = aws_ecs_cluster.ecs_cluster.id                  # Associate the service with the ECS cluster
  task_definition = aws_ecs_task_definition.app_task_definition.arn # Use the task definition created earlier
  desired_count   = var.desired_count                               # Number of tasks to run
  launch_type     = "FARGATE"                                       # Use Fargate for serverless container deployment

  network_configuration {
    subnets          = module.vpc.private_subnets             # Use private subnets for the tasks
    security_groups  = [aws_security_group.ecs_service_sg.id] # Security group for the ECS service
    assign_public_ip = false                                  # Do not assign a public IP to the tasks
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.graphite_target_group.arn # Link service to the target group
    container_name   = "graphite"                                    # Specify the container to link to the load balancer
    container_port   = 80                                            # Port of the container linked to the load balancer
  }
  force_new_deployment = true # Force deployment of a new version if changes are detected

  # Ensure ECS service depends on the ECS task definition and load balancer
  depends_on = [
    aws_ecs_task_definition.app_task_definition,
    aws_lb.application_lb
  ]
}

# Security Group for the ECS service, defining inbound and outbound rules
resource "aws_security_group" "ecs_service_sg" {
  name   = "ecs-service-sg-${var.environment}" # Security group name based on the environment
  vpc_id = module.vpc.vpc_id                   # Associate the security group with the VPC

  # Inbound rules for Node.js app
  ingress {
    from_port   = 3000 # Allow inbound traffic on port 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # Restrict access to within the VPC
  }

  # Inbound rules for Graphite HTTP (port 80)
  ingress {
    from_port   = 80 # Allow inbound traffic on port 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow access from anywhere (public)
  }

  # Inbound rules for Graphite Metrics (port 2003)
  ingress {
    from_port   = 2003 # Allow inbound traffic on port 2003
    to_port     = 2003
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # Restrict access to within the VPC
  }

  # Outbound rules allowing all traffic
  egress {
    from_port   = 0 # Allow all outbound traffic
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow outbound access to anywhere
  }

  # Ensure security group creation depends on the VPC
  depends_on = [
    module.vpc
  ]
}

# Application Load Balancer to distribute traffic to the ECS service
resource "aws_lb" "application_lb" {
  name               = "ecs-app-lb-${var.environment}"            # Load balancer name based on the environment
  internal           = false                                      # External load balancer for public access
  load_balancer_type = "application"                              # Application load balancer type
  security_groups    = [aws_security_group.alb_security_group.id] # Security group for the load balancer
  subnets            = module.vpc.public_subnets                  # Use public subnets for the load balancer

  enable_deletion_protection = false # Disable deletion protection for easier cleanup

  # Ensure load balancer creation depends on the VPC
  depends_on = [
    module.vpc
  ]
}

# Target Group for the Graphite container, linking it to the load balancer
resource "aws_lb_target_group" "graphite_target_group" {
  name        = "graphite-tg-${var.environment}" # Target group name based on the environment
  port        = 80                               # Port used by the target group
  protocol    = "HTTP"                           # Use HTTP for traffic routing
  vpc_id      = module.vpc.vpc_id                # Associate the target group with the VPC
  target_type = "ip"                             # Route traffic to the IP address of the ECS tasks

  # Ensure target group creation depends on the VPC
  depends_on = [
    module.vpc
  ]
}

# Listener for the load balancer to forward HTTP traffic to the target group
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.application_lb.arn # Associate the listener with the load balancer
  port              = "80"                      # Listen on port 80 for incoming HTTP traffic
  protocol          = "HTTP"                    # Use HTTP protocol

  default_action {
    type             = "forward"                                     # Forward traffic to the target group
    target_group_arn = aws_lb_target_group.graphite_target_group.arn # Specify the target group
  }

  # Ensure listener creation depends on the load balancer and target group
  depends_on = [
    aws_lb.application_lb,
    aws_lb_target_group.graphite_target_group
  ]
}

# Security Group for the Application Load Balancer, defining inbound and outbound rules
resource "aws_security_group" "alb_security_group" {
  name   = "ecs-alb-sg-${var.environment}" # Security group name based on the environment
  vpc_id = module.vpc.vpc_id               # Associate the security group with the VPC

  # Inbound rules for the ALB (port 80)
  ingress {
    from_port   = 80 # Allow inbound traffic on port 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow access from anywhere (public)
  }

  # Outbound rules allowing all traffic
  egress {
    from_port   = 0 # Allow all outbound traffic
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow outbound access to anywhere
  }

  # Ensure security group creation depends on the VPC
  depends_on = [
    module.vpc
  ]
}