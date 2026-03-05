# Terraform Instancias Ociosas

Projeto Terraform para criar uma EC2 com Nginx e agendar `start/stop` automatico via EventBridge + SSM.

## Requisitos

- Terraform instalado
- AWS CLI configurado (`aws configure`)
- Permissoes para EC2, IAM, EventBridge e SSM

## Uso rapido

```bash
terraform init
terraform plan
terraform apply
```

Para remover tudo:

```bash
terraform destroy
```

## Observacoes

- Regiao configurada: `us-east-1`
- Os horarios de agendamento estao em UTC no `main.tf`