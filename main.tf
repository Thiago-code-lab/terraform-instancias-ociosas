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
# 1. Security Group
# ==========================================
resource "aws_security_group" "web_sg" {
  name        = "docker-web-sg"
  description = "Permite trafego HTTP e SSH"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrinja ao seu IP em producao
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "docker-web-sg" }
}

# ==========================================
# 2. AMI Amazon Linux 2023
# ==========================================
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ==========================================
# 3. Busca automatica do tipo free tier elegivel
# ==========================================
data "aws_ec2_instance_types" "free_tier" {
  filter {
    name   = "free-tier-eligible"
    values = ["true"]
  }
}

locals {
  # Prefere t2.micro, senao usa o primeiro elegivel encontrado
  free_tier_type = contains(
    data.aws_ec2_instance_types.free_tier.instance_types, "t2.micro"
  ) ? "t2.micro" : tolist(data.aws_ec2_instance_types.free_tier.instance_types)[0]
}

# ==========================================
# 4. Instancia EC2 (tipo detectado automaticamente)
# ==========================================
resource "aws_instance" "docker_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = local.free_tier_type

  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/user-data.log 2>&1

    echo "==> Atualizando sistema..."
    dnf update -y

    echo "==> Instalando Docker..."
    dnf install -y docker
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    echo "==> Instalando Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
      | grep '"tag_name"' | cut -d'"' -f4)
    curl -SL "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    echo "==> Criando aplicacao..."
    mkdir -p /app/html

    cat > /app/html/index.html <<'HTML'
    <!DOCTYPE html>
    <html lang="pt-br">
      <head><meta charset="UTF-8"><title>Free Tier Test</title></head>
      <body>
        <h1>Funcionando no Free Tier!</h1>
        <p>Docker + Nginx rodando na EC2 t2.micro</p>
      </body>
    </html>
    HTML

    cat > /app/docker-compose.yml <<'COMPOSE'
    version: '3.8'
    services:
      nginx:
        image: nginx:alpine
        container_name: meu-site
        ports:
          - "80:80"
        volumes:
          - ./html:/usr/share/nginx/html:ro
        restart: always
    COMPOSE

    echo "==> Subindo containers..."
    cd /app && /usr/local/bin/docker-compose up -d

    cat > /etc/systemd/system/docker-app.service <<'SERVICE'
    [Unit]
    Description=Docker Compose App
    Requires=docker.service
    After=docker.service network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    WorkingDirectory=/app
    ExecStart=/usr/local/bin/docker-compose up -d
    ExecStop=/usr/local/bin/docker-compose down
    TimeoutStartSec=120

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable docker-app.service

    echo "==> Tudo pronto!"
  EOF

  tags = { Name = "EC2-Docker-FreeTier" }
}

# ==========================================
# 4. Elastic IP
#
# FREE TIER ATENCAO:
# Gratuito enquanto associado a instancia RODANDO.
# Quando a instancia esta PARADA: ~$0.005/hora.
# Estimativa com os agendamentos abaixo: ~$0.59/mes.
#
# Se quiser custo zero: remova este recurso e
# use o output "ip_dinamico" (IP muda a cada religar).
# ==========================================
resource "aws_eip" "ip_fixo" {
  instance   = aws_instance.docker_server.id
  domain     = "vpc"
  depends_on = [aws_instance.docker_server]
  tags       = { Name = "IP-Fixo-Docker" }
}

# ==========================================
# 5. IAM Role para EventBridge Scheduler
# ==========================================
resource "aws_iam_role" "scheduler_role" {
  name = "EventBridgeSchedulerEC2Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "EventBridgeSchedulerEC2Policy"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StopInstances", "ec2:StartInstances"]
      Resource = [aws_instance.docker_server.arn]
    }]
  })
}

# ==========================================
# 6. Desligar - 22:00 BRT, Seg a Sex
# ==========================================
resource "aws_scheduler_schedule" "stop_ec2" {
  name        = "stop-docker-ec2-22h"
  description = "Desliga as 22:00 BRT de segunda a sexta"

  flexible_time_window { mode = "OFF" }

  schedule_expression          = "cron(0 22 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Sao_Paulo"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ InstanceIds = [aws_instance.docker_server.id] })
  }
}

# ==========================================
# 7. Ligar - 06:00 BRT, Seg a Sex
# Sexta 22h desliga, sabado/domingo sem schedule
# de start, segunda 06h religa automaticamente.
# ==========================================
resource "aws_scheduler_schedule" "start_ec2" {
  name        = "start-docker-ec2-6h"
  description = "Liga as 06:00 BRT de segunda a sexta"

  flexible_time_window { mode = "OFF" }

  schedule_expression          = "cron(0 6 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Sao_Paulo"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ InstanceIds = [aws_instance.docker_server.id] })
  }
}

# ==========================================
# 8. Outputs
# ==========================================
output "ip_publico_do_site" {
  value       = aws_eip.ip_fixo.public_ip
  description = "IP fixo — use para DNS. Nunca muda com stop/start."
}

output "ip_dinamico" {
  value       = aws_instance.docker_server.public_ip
  description = "IP direto da instancia (muda a cada religar — evite usar)"
}

output "instance_id" {
  value = aws_instance.docker_server.id
}

output "verificar_logs" {
  value       = "ssh -i SUA_CHAVE.pem ec2-user@${aws_eip.ip_fixo.public_ip} 'sudo cat /var/log/user-data.log'"
  description = "Comando para checar se o user-data rodou corretamente"
}
