# Terraform state file will be stored in S3 and setting provider to AWS
terraform {
  backend "s3" {
    bucket         = "zach-nginx-demo-tf"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locking"
    encrypt        = true
  }
  required_providers {
    aws = {
      version = ">= 2.7.0"
      source  = "hashicorp/aws"
    }
  }
}
# Setting default region
provider "aws" {
  region = "us-east-1"
}
# S3 bucket where Terraform state file is stored + Enabling bucket versioning & encryption
resource "aws_s3_bucket" "terraform_state" {
  bucket = "zach-nginx-demo-tf"
}

resource "aws_s3_bucket_acl" "bucket_acl" {
  bucket = aws_s3_bucket.terraform_state.bucket
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "versioning_enabled" {
  bucket = aws_s3_bucket.terraform_state.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_encryption" {
  bucket = aws_s3_bucket.terraform_state.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Creating a dynamoDB table so statefile can be locked
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-state-locking"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
# Creating VPC using official/verified AWS module found at: https://github.com/terraform-aws-modules/terraform-aws-vpc 
module "nginx-demo-vpc" {
  version = "~> 3.14.0"
  source  = "terraform-aws-modules/vpc/aws"

  name = join("-", [var.name, "vpc"])
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true

  tags = {
    Terraform = "true"
    Solution  = var.name
  }
}
# using data block for latest Amazon Linux AMI
data "aws_ssm_parameter" "amzn-ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

data "aws_ssm_parameter" "eks-kms-key" {
  name = "nginx-demo-eks-kms-key"
}

data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 18.0"

  cluster_name    = "zach-nginx-demo"
  cluster_version = "1.23"

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  cluster_addons = {
    coredns = {
      resolve_conflicts = "OVERWRITE"
    }
    kube-proxy = {}
    vpc-cni = {
      resolve_conflicts = "OVERWRITE"
    }
  }

  cluster_encryption_config = [{
    provider_key_arn = "arn:aws:kms:us-east-1:${data.aws_caller_identity.current.account_id}:key/a9387f7a-2bbc-4245-a22e-3b6a9ac28828"
    resources        = ["secrets"]
  }]

  vpc_id     = module.nginx-demo-vpc.vpc_id
  subnet_ids = module.nginx-demo-vpc.private_subnets


  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    disk_size      = 10
    instance_types = [var.default_instance_type]
  }

  eks_managed_node_groups = {
    nginx_demo_node_group1 = {}
    nginx_demo_node_group2 = {
      min_size     = 1
      max_size     = 3
      desired_size = 1

      instance_types = [var.default_instance_type]
      capacity_type  = "ON_DEMAND"
      update_config = {
      max_unavailable_percentage = 50 # or set `max_unavailable`
      }
    }
  }

  # aws-auth configmap
  manage_aws_auth_configmap = false

  aws_auth_roles = [
    {
      rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/EKS-node-instance"
      username = "system"
      groups   = ["system:masters"]
    },
  ]

  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/zachrundle"
      username = "zachrundle"
      groups   = ["system:masters"]
    }
  ]

  aws_auth_accounts = [
    "${data.aws_caller_identity.current.account_id}"
  ]

  tags = {
    Name      = "zach-nginx-demo"
    Terraform = "true"
  }
}

#ran terraform import since NLB was created by K8s service file
resource "aws_lb" "NLB" {
      enable_cross_zone_load_balancing = false
      enable_deletion_protection = false
      internal = false
      ip_address_type = "ipv4"
      load_balancer_type = "network"
      name = "a8bdc1a5f27d047baa8ea178f3fc03d7"
      security_groups = []
      subnets = [
          "subnet-02532e7063032b43a",
          "subnet-0b62c66198deb2b3d",
        ]
      tags = {
          "kubernetes.io/cluster/zach-nginx-demo" = "owned"
          "kubernetes.io/service-name"            = "default/zach-nginx-demo"
        }

      subnet_mapping {
          subnet_id = "subnet-02532e7063032b43a"
        }
      subnet_mapping {
          subnet_id = "subnet-0b62c66198deb2b3d"
        }
      timeouts {}
}


# Configure Prometheus server for monitoring (still work in progress)

resource "aws_security_group" "prometheus" {
  name        = "nginx-demo-prometheus"
  description = "prometheus monitoring server"
  vpc_id      = module.nginx-demo-vpc.vpc_id


  ingress {
    description = "HTTP"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_network_interface" "web-server-nic" {
  subnet_id       = "10.0.2.0/24"
  private_ips     = ["10.0.2.50"]
  security_groups = [aws_security_group.prometheus.id]
}


resource "aws_instance" "prometheus" {
  ami           = data.aws_ssm_parameter.amzn-ami.id
  instance_type = "t3.micro"
  availability_zone = "us-east-1a"
  key_name      = "prometheus"
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web-server-nic.id
  }

  user_data = <<-EOF
      #!/bin/bash
      wget https://github.com/prometheus/prometheus/releases/download/v2.37.1/prometheus-2.37.1.linux-amd64.tar.gz
      sleep 2m
      tar -xzf prometheus-2.37.1.linux-amd64.tar.gz
      sleep 10
      cd prometheus-2.37.1.linux-amd64/
      ./prometheus
      EOF

  tags = {
    Name = "prometheus"
  }
}

