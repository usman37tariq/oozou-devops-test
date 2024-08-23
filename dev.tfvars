environment       = "dev"
region            = "eu-central-1"
profile           = "playground"
vpc_cidr          = "10.9.0.0/16"
azs               = ["eu-central-1a", "eu-central-1b"]
private_subnets   = ["10.9.1.0/24", "10.9.2.0/24"]
public_subnets    = ["10.9.101.0/24", "10.9.102.0/24"]
retention_in_days = 7
desired_count     = 1
cpu               = 512
memory            = 1024
