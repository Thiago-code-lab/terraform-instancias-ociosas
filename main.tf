terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ==========================================
# 1. Security Group (Liberar Porta 80 para o Nginx)
# ==========================================
resource "aws_security_group" "web_sg" {
  name        = "docker-web-sg"
  description = "Permite trafego HTTP de entrada"

  ingress {
    from_port   = 80
    to_port     = 80
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

# ==========================================
# 2. Instância EC2 com Docker (User Data)
# ==========================================
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "docker_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y docker
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user
              docker run -d -p 80:80 --name meu-site nginx
              EOF

  tags = {
    Name = "EC2-Docker-Agendado"
  }
}

# ==========================================
# 3. IP Fixo (Elastic IP)
# ==========================================
resource "aws_eip" "ip_fixo" {
  instance = aws_instance.docker_server.id
  domain   = "vpc"

  tags = {
    Name = "IP-Fixo-Docker"
  }
}

# ==========================================
# 4. IAM Role para o EventBridge (Permissão para Ligar/Desligar)
# ==========================================
resource "aws_iam_role" "eventbridge_ssm_role" {
  name = "EventBridgeSSMEC2Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_ssm_policy" {
  name = "EventBridgeSSMEC2Policy"
  role = aws_iam_role.eventbridge_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:StartAutomationExecution"]
        Resource = [
          "arn:aws:ssm:us-east-1::automation-definition/AWS-StopEC2Instance",
          "arn:aws:ssm:us-east-1::automation-definition/AWS-StartEC2Instance"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances", "ec2:DescribeInstanceStatus"]
        Resource = [aws_instance.docker_server.arn]
      }
    ]
  })
}

# ==========================================
# 5. Agendamento - Desligar às 16:50 BRT (19:50 UTC)
# ==========================================
resource "aws_cloudwatch_event_rule" "stop_ec2_rule" {
  name                = "stop-docker-ec2"
  description         = "Desliga a instancia as 16h50 (BRT)"
  schedule_expression = "cron(50 19 * * ? *)"
}

resource "aws_cloudwatch_event_target" "stop_ec2_target" {
  rule      = aws_cloudwatch_event_rule.stop_ec2_rule.name
  target_id = "StopEC2"
  arn       = "arn:aws:ssm:us-east-1::automation-definition/AWS-StopEC2Instance"
  role_arn  = aws_iam_role.eventbridge_ssm_role.arn

  input = jsonencode({
    InstanceId = [aws_instance.docker_server.id]
  })
}

# ==========================================
# 6. Agendamento - Ligar às 16:55 BRT (19:55 UTC)
# ==========================================
resource "aws_cloudwatch_event_rule" "start_ec2_rule" {
  name                = "start-docker-ec2"
  description         = "Liga a instancia as 16h55 (BRT)"
  schedule_expression = "cron(55 19 * * ? *)"
}

resource "aws_cloudwatch_event_target" "start_ec2_target" {
  rule      = aws_cloudwatch_event_rule.start_ec2_rule.name
  target_id = "StartEC2"
  arn       = "arn:aws:ssm:us-east-1::automation-definition/AWS-StartEC2Instance"
  role_arn  = aws_iam_role.eventbridge_ssm_role.arn

  input = jsonencode({
    InstanceId = [aws_instance.docker_server.id]
  })
}

# ==========================================
# 7. Outputs
# ==========================================
output "ip_publico_do_site" {
  value       = aws_eip.ip_fixo.public_ip
  description = "Acesse este IP no navegador para ver o Nginx rodando"
}