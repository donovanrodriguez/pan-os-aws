terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "prefix" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "vpc_id" { type = string }
variable "web_subnet_id" { type = string }
variable "db_subnet_ids" {
  description = "db-a + db-b subnet IDs (different AZs) for the RDS subnet group."
  type        = list(string)
}
variable "web_subnet_cidr" { type = string }
variable "instance_type" { type = string }
variable "key_name" { type = string }
variable "mysql_admin_username" { type = string }
variable "mysql_admin_password" {
  type      = string
  sensitive = true
}
variable "mysql_instance_class" { type = string }
variable "mysql_storage_gb" { type = number }

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "web" {
  name        = "${var.prefix}-nginx-web-sg"
  description = "All inbound (already inspected by FW trust)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.prefix}-nginx-web-sg" })

  ingress {
    description = "All inbound (already inspected by FW trust)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.web_subnet_id
  vpc_security_group_ids = [aws_security_group.web.id]
  tags                   = merge(var.tags, { Name = "${var.prefix}-nginx-web" })

  user_data = <<-EOT
    #!/bin/bash
    set -eux
    apt-get update
    apt-get install -y nginx mysql-client
    echo "<h1>nginx behind PAN VM-Series via AWS TGW hub-and-spoke</h1>" > /var/www/html/index.html
    systemctl enable --now nginx
  EOT
}

resource "aws_security_group" "db" {
  name        = "${var.prefix}-mysql-db-sg"
  description = "MySQL from the web subnet only"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.prefix}-mysql-db-sg" })

  ingress {
    description = "MySQL from web subnet"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.web_subnet_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "mysql" {
  name       = "${var.prefix}-mysql-subnets"
  subnet_ids = var.db_subnet_ids
  tags       = var.tags
}

resource "aws_db_instance" "mysql" {
  identifier     = "${var.prefix}-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.mysql_instance_class

  allocated_storage = var.mysql_storage_gb
  storage_type      = "gp3"

  db_name  = "appdb"
  username = var.mysql_admin_username
  password = var.mysql_admin_password

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az            = false
  publicly_accessible = false

  # Lab-friendly teardown; enable both for production data.
  skip_final_snapshot = true
  deletion_protection = false

  tags = var.tags
}

output "nginx_private_ip" { value = aws_instance.nginx.private_ip }
output "mysql_endpoint" { value = aws_db_instance.mysql.address }
output "mysql_db_instance_id" { value = aws_db_instance.mysql.id }
