# Plano de Continuidade de Negócios e Disaster Recovery — SolidaryTech

**Projeto:** POSTECH — Hackathon DCLT / Fase 5  
**Responsável:** Bruno Marcomini  
**GitHub:** Krohanar  
**Ambiente primário:** AWS `us-east-1`  
**Região de DR:** AWS `us-west-2`  
**Versão:** 1.0 — 27/07/2026

## 1. Objetivo executivo

Preservar o recebimento, a integridade e a rastreabilidade das doações quando houver falha de aplicação, cluster, banco de dados ou indisponibilidade regional.

A estratégia atual é de **backup e restauração (cold recovery)**:

- Infraestrutura versionada em Terraform.
- Entrega GitOps por ArgoCD.
- Backup horário do estado Kubernetes com Velero para S3 em `us-west-2`.
- Backups automatizados do Amazon RDS PostgreSQL com retenção de 7 dias e Point-in-Time Recovery.
- Replicação cross-region dos backups automatizados do RDS para `us-west-2`, com criptografia KMS.

> **Compromisso para o pior cenário:** RTO de **4 horas** e RPO de **1 hora** em desastre regional completo.

## 2. Escopo e criticidade

| Prioridade | Componente | Impacto | Tratamento |
|---|---|---|---|
| P0 | `donation-service` + `donation_db` | Doações não são processadas ou consultadas | Recuperação imediata |
| P1 | SQS `solidary-donations` | Eventos assíncronos ficam represados | Recriação via Terraform e replay a partir do RDS |
| P1 | EKS / ArgoCD | Aplicações deixam de executar | Terraform + GitOps + Velero |
| P2 | Observabilidade | Aumento do MTTR | Restaurar após o caminho crítico |
| P2 | `ngo-service` / `volunteer-service` | Funções administrativas degradadas | Recuperar após doações |

## 3. RTO e RPO

| Cenário | RTO | RPO |
|---|---:|---:|
| Falha de Pod/Deployment | 15 min | 0 para dados persistidos |
| Falha do EKS na região primária | 2 h | 1 h para estado Kubernetes |
| Corrupção lógica/falha isolada do RDS | 2 h | até 15 min |
| Desastre completo em `us-east-1` | 4 h | 1 h |

O RTO começa na declaração formal do desastre. O RPO é medido pelo último backup Velero `Completed` e pelo `LatestRestorableTime` do RDS.

## 4. Controles implementados

- Velero `v1.18.1` com plugin AWS.
- Schedule: `0 * * * *`.
- Namespaces protegidos: `solidarytech`, `monitoring` e `argocd`.
- Bucket: `solidarytech-velero-dr-106978078844-us-west-2`.
- Prefixo: `solidarytech-production`.
- TTL: `168h` (7 dias).
- RDS PostgreSQL com backups automáticos e retenção de 7 dias.
- Replicação de snapshots e transaction logs para `us-west-2`.
- KMS de destino: alias `alias/solidarytech-rds-dr`.

### Evidência prática

O backup `solidarytech-dr-backup-20260727-101709` terminou `Completed`, com 3/3 itens. O namespace de origem foi excluído e o restore `solidarytech-dr-restore-20260727-101709` recriou o ConfigMap `solidarytech-dr-proof` em outro namespace, preservando a mensagem `Velero restore succeeded`.

## 5. Critérios de ativação

- `donation-service` indisponível sem recuperação em 15 minutos.
- Perda do EKS ou indisponibilidade regional.
- Corrupção do PostgreSQL que exija PITR.
- Ausência de ponto restaurável válido dentro do RPO.
- Risco de perda de dados superior ao limite aprovado.

## 6. Runbook resumido

### Primeiros 15 minutos

1. Confirmar o incidente em New Relic, Prometheus/Grafana e Loki.
2. Abrir/atualizar Jira e Discord.
3. Registrar início, impacto e último estado saudável.
4. Suspender mudanças não relacionadas.
5. Classificar: aplicação, cluster, banco ou região.

### Falha do cluster

1. Validar ArgoCD e eventos do Kubernetes.
2. Permitir self-healing e reconciliação.
3. Reprovisionar via Terraform quando necessário.
4. Instalar/sincronizar ArgoCD e Velero.
5. Restaurar o último backup `Completed`.
6. Validar Pods, health checks, métricas, logs e uma doação.

### Falha do RDS

1. Identificar o ponto anterior à corrupção.
2. Criar nova instância por Point-in-Time Recovery.
3. Validar integridade e contagem dos dados.
4. Atualizar endpoint de forma segura.
5. Testar POST/GET e publicação no SQS.

### Desastre regional

1. Ativar o PCN e usar `us-west-2`.
2. Provisionar infraestrutura pela configuração Terraform.
3. Restaurar RDS do backup automatizado replicado.
4. Instalar ArgoCD e Velero.
5. Restaurar os recursos Kubernetes.
6. Recriar SQS e reconciliar eventos a partir do RDS.
7. Atualizar endpoint de entrada.
8. Validar negócio e observabilidade antes do retorno.

## 7. Validação de retorno

- RDS disponível e restaurável.
- Deployments e Pods `Ready`.
- ArgoCD `Synced/Healthy`.
- POST `/donations` retorna HTTP 201.
- GET `/donations` retorna o registro.
- Evento SQS confirmado ou reconciliado.
- Trace no New Relic.
- SLIs/SLOs e Error Budget dentro do limite.
- Alertas encerrados.

## 8. Riscos residuais

- RDS Single-AZ.
- Ausência de cluster warm standby.
- SQS sem replicação cross-region.
- DynamoDB sem Global Tables.
- Cutover sem DNS global automatizado.
- Replicação cross-region assíncrona sem garantia interna de lag.

## 9. Melhorias recomendadas

- RDS Multi-AZ.
- EKS mínimo em standby na região de DR.
- Route 53 com health checks e failover.
- Outbox transacional para replay confiável de eventos.
- DynamoDB Global Tables.
- Alerta sobre diferença entre horário atual e `LatestRestorableTime`.
- Exercício semestral de recuperação regional.

## 10. Frequência de testes

- Mensal: status dos backups e replicação.
- Trimestral: restore em namespace isolado.
- Semestral: tabletop ou simulação regional.
- Após incidentes/mudanças: revisão do PCN.
