# FinOps — SolidaryTech

## 1. Objetivo

Esta análise FinOps tem como objetivo justificar financeiramente a infraestrutura da SolidaryTech, identificar desperdícios, aplicar uma estratégia de tagging e produzir uma projeção mensal dos custos da arquitetura hospedada na AWS.

A análise foi executada sobre a conta AWS pessoal utilizada no projeto, na região `us-east-1`.

## 2. Requisitos atendidos

A implementação FinOps cobre:

- Política obrigatória de tags aplicada pelo Terraform.
- Inventário dos recursos AWS.
- Coleta de CPU e memória do Kubernetes.
- Rightsizing dos microsserviços.
- Alteração de requests e limits via GitOps.
- Forecast mensal bottom-up.
- Recomendações de otimização nativas da AWS.

## 3. Estratégia de tagging

Os recursos criados pelo Terraform utilizam as seguintes tags:

| Tag | Valor |
|---|---|
| Project | SolidaryTech |
| Environment | Production |
| CostCenter | NGO-Core |
| Owner | FIAP |
| ManagedBy | Terraform |

Durante a auditoria foram encontrados 20 recursos contendo simultaneamente as três tags obrigatórias:

- `Project=SolidaryTech`
- `Environment=Production`
- `CostCenter=NGO-Core`

As tags permitem agrupar os custos do projeto, separar ambientes, identificar o centro de custo responsável e gerar relatórios no AWS Cost Explorer.

## 4. Inventário financeiro

| Recurso | Configuração |
|---|---|
| Região AWS | us-east-1 |
| EKS | solidarytech-production |
| Kubernetes | 1.36 |
| Worker nodes | 4 unidades t3.small On-Demand |
| Disco dos workers | 4 volumes de 20 GB gp3 |
| IPv4 público | 4 endereços |
| RDS | db.t3.micro PostgreSQL Single-AZ |
| Storage do RDS | 20 GB gp3 |
| ECR | 3 repositórios privados |
| Armazenamento ECR | aproximadamente 0,8575 GB |
| SQS | solidary-donations |
| DynamoDB | SolidaryTechVolunteers |
| NAT Gateway | nenhum |
| Load Balancer AWS | nenhum |
| CloudWatch Log Groups | nenhum no momento da coleta |

## 5. Metodologia do Forecast

O Forecast utiliza uma abordagem bottom-up.

Cada recurso provisionado foi identificado e multiplicado pelo respectivo preço unitário. Foram consideradas 730 horas por mês.

Os preços de EC2, EBS e RDS foram consultados pela AWS Price List Query API por meio do script:

`scripts/generate-finops-forecast.ps1`

Os resultados estruturados foram gravados nos arquivos:

- `docs/finops/forecast-monthly.csv`
- `docs/finops/forecast-summary.json`

## 6. Forecast mensal

| Componente | Configuração | Custo mensal |
|---|---|---:|
| EKS control plane | 1 cluster | USD 73,00 |
| EC2 worker nodes | 4 unidades t3.small On-Demand | USD 60,74 |
| EBS dos worker nodes | 80 GB gp3 | USD 6,40 |
| IPv4 público | 4 endereços | USD 14,60 |
| RDS PostgreSQL | 1 unidade db.t3.micro Single-AZ | USD 13,14 |
| RDS storage | 20 GB gp3 | USD 2,30 |
| ECR privado | 0,8575 GB | USD 0,09 |
| Serviços variáveis | S3, SQS, DynamoDB, Secrets e APIs | USD 1,00 |
| **Total mensal** |  | **USD 171,27** |
| **Total anual** |  | **USD 2.055,24** |

## 7. Distribuição dos custos

Os dois maiores componentes são:

| Componente | Participação aproximada |
|---|---:|
| EKS control plane | 42,6% |
| EC2 worker nodes | 35,5% |
| Demais componentes | 21,9% |

EKS e EC2 representam juntos aproximadamente 78,1% do Forecast mensal.

Assim, as otimizações financeiras com maior impacto futuro devem se concentrar principalmente na capacidade computacional do cluster.

## 8. Cost Explorer

O Forecast inicial do AWS Cost Explorer apresentou um valor muito baixo porque a infraestrutura foi criada recentemente e a conta ainda não possuía histórico suficiente.

O valor estatístico previsto para o mês seguinte foi de aproximadamente USD 0,19.

Esse valor foi preservado como evidência da consulta oficial, mas não foi utilizado como projeção principal, pois ainda não incluía adequadamente os custos do EKS, EC2, RDS e demais recursos recém-provisionados.

Por esse motivo, a projeção oficial do projeto utiliza o Forecast bottom-up de USD 171,27 por mês.

## 9. Coleta de métricas para Rightsizing

O Metrics Server foi instalado no EKS por meio do Terraform:

`infra/environments/dev/metrics-server.tf`

A API de métricas foi validada com o seguinte estado:

- API: `v1beta1.metrics.k8s.io`
- Available: `True`
- Add-on AWS: `ACTIVE`
- Réplicas: `2/2`

Foram coletadas dez amostras de CPU e memória durante aproximadamente cinco minutos.

### Resultado do cluster

| Métrica | Média | Pico | Capacidade alocável |
|---|---:|---:|---:|
| CPU | 273,7m | 342m | 7.720m |
| Memória | 4.041 MiB | 4.073 MiB | 5.733 MiB |

A utilização de CPU permaneceu próxima de 3,5%, enquanto a utilização de memória permaneceu próxima de 70%.

### Consumo dos microsserviços

| Serviço | CPU por Pod | Memória por Pod |
|---|---:|---:|
| donation-service | aproximadamente 1m | 8 a 10 MiB |
| ngo-service | aproximadamente 1m | 64 a 67 MiB |
| volunteer-service | aproximadamente 1m | 96 a 98 MiB |

### Maiores consumidores do cluster

| Componente | Memória observada |
|---|---:|
| Prometheus | 415 a 430 MiB |
| Grafana | aproximadamente 190 MiB |
| Sidecars do Grafana | aproximadamente 149 MiB |
| ArgoCD Application Controller | 133 a 158 MiB |
| Loki | 86 a 104 MiB |

A maior parte da memória é consumida pelas ferramentas de observabilidade, GitOps e componentes internos do Kubernetes, e não pelos três microsserviços.

## 10. Decisão sobre o node group

Apesar da grande ociosidade de CPU, não foi considerada segura uma redução imediata de quatro para três nodes t3.small.

Cada node disponibiliza aproximadamente:

- 1.930m de CPU.
- 1.467.764 KiB de memória.
- Limite de 11 Pods.

Com quatro nodes, a capacidade máxima aproximada é de 44 Pods.

Durante a coleta foram encontrados aproximadamente 41 Pods vinculados aos nodes. Com três nodes, a capacidade cairia para apenas 33 Pods.

Além disso, a memória alocável ficaria muito próxima do consumo já observado.

Uma redução imediata poderia provocar:

- Pods em estado Pending.
- Falhas durante rolling updates.
- Falhas no Self-Healing.
- Falta de margem durante picos do Prometheus.
- Indisponibilidade durante substituição ou manutenção de nodes.

Por isso, o node group foi mantido com:

| Propriedade | Valor |
|---|---:|
| desired_size | 4 |
| min_size | 2 |
| max_size | 4 |

O Terraform foi atualizado para representar a infraestrutura real, e o plano confirmou:

`No changes. Your infrastructure matches the configuration.`

## 11. Rightsizing dos microsserviços

### Configuração anterior

| Serviço | CPU request | Memória request | CPU limit | Memória limit |
|---|---:|---:|---:|---:|
| donation-service | 150m | 128 MiB | 500m | 256 MiB |
| ngo-service | 100m | 128 MiB | 300m | 256 MiB |
| volunteer-service | 100m | 128 MiB | 300m | 256 MiB |

### Configuração aplicada

| Serviço | CPU request | Memória request | CPU limit | Memória limit |
|---|---:|---:|---:|---:|
| donation-service | 50m | 64 MiB | 300m | 192 MiB |
| ngo-service | 50m | 96 MiB | 200m | 192 MiB |
| volunteer-service | 50m | 128 MiB | 200m | 256 MiB |

As alterações foram realizadas no manifesto:

`k8s/base/03-services.yaml`

O deploy foi aplicado pelo ArgoCD usando a branch `fase-5-implementacao`.

O estado final da aplicação foi:

- Sync: `Synced`
- Health: `Healthy`
- Réplicas de cada serviço: `2/2`

## 12. Eficiência obtida

Considerando duas réplicas de cada serviço:

| Recurso configurado | Antes | Depois | Redução |
|---|---:|---:|---:|
| CPU requests | 700m | 300m | 57,1% |
| Memória requests | 768 MiB | 576 MiB | 25,0% |
| CPU limits | 2.200m | 1.400m | 36,4% |
| Memória limits | 1.536 MiB | 1.280 MiB | 16,7% |

O Rightsizing não reduz diretamente a cobrança enquanto o número de instâncias EC2 permanecer fixo.

A melhoria obtida é operacional:

- Redução de reservas excessivas.
- Melhor aproveitamento do scheduler.
- Mais capacidade para rolling updates.
- Menor risco de escala causada por requests irreais.
- Maior margem para recuperação automática.
- Manifestos alinhados ao consumo observado.

## 13. Otimizações práticas implementadas

### Rightsizing via GitOps

Os recursos dos Pods foram ajustados com base em métricas reais e implantados automaticamente pelo ArgoCD.

### Lifecycle Policy no ECR

Os três repositórios ECR possuem lifecycle policies configuradas pelo Terraform.

Isso impede o crescimento indefinido de imagens antigas e evita aumento contínuo do custo de armazenamento.

### Ausência de NAT Gateway

A arquitetura atual não utiliza NAT Gateway, evitando cobrança fixa por hora e cobrança por volume de dados processado.

## 14. Recomendações futuras

### Compute Savings Plan

Após pelo menos 30 dias de utilização estável, devem ser analisadas as recomendações do AWS Cost Explorer para avaliar um Compute Savings Plan para a carga base dos worker nodes.

Não foi assumido compromisso de um ou três anos nesta fase porque a conta ainda não possui histórico suficiente.

### Reserved Instance para RDS

Caso o PostgreSQL permaneça ligado continuamente, deve ser avaliada uma Reserved Instance para o RDS depois que o padrão de utilização estiver consolidado.

### AWS Budgets

Recomenda-se configurar alertas de orçamento nos seguintes limites:

- USD 150.
- USD 175.
- USD 200.

### Revisão periódica

A análise de Rightsizing deve ser repetida mensalmente com uma janela maior de métricas para capturar picos, crescimento de tráfego, aumento da base, logs e traces.

### Cost Allocation Tags

As tags já estão aplicadas aos recursos. Também é necessário confirmar no Billing da AWS se `Project`, `Environment` e `CostCenter` estão ativadas como Cost Allocation Tags.

## 15. Limitações da projeção

O Forecast não considera de maneira exata:

- Impostos.
- Créditos promocionais.
- Free Tier.
- Transferência de dados variável.
- Crescimento futuro de tráfego.
- Snapshots além da retenção gratuita.
- Crescimento futuro de logs e traces.
- Variações cambiais.

Foi adicionada uma contingência de USD 1,00 para serviços de uso variável que apresentavam consumo mínimo durante a coleta.

## 16. Evidências recomendadas

As seguintes evidências devem ser incluídas no PDF final:

1. Recursos AWS com as tags obrigatórias.
2. Terraform mostrando `No changes`.
3. Metrics Server ativo.
4. Saída de `kubectl top nodes`.
5. Saída de `kubectl top pods --containers`.
6. Requests e limits antes do Rightsizing.
7. Requests e limits depois do Rightsizing.
8. ArgoCD mostrando `Synced` e `Healthy`.
9. Forecast mensal no terminal.
10. Consulta inicial do Cost Explorer.
11. Repositórios ECR e lifecycle policies.

## 17. Conclusão

A arquitetura SolidaryTech apresenta um Forecast mensal estimado de USD 171,27 e um Forecast anual de USD 2.055,24.

A análise demonstrou que a maior oportunidade financeira está relacionada ao EKS e aos worker nodes, responsáveis por aproximadamente 78,1% do custo.

A redução imediata do número de nodes não foi considerada segura devido ao consumo de memória e ao limite de Pods.

Em vez disso, foi implementado Rightsizing nos microsserviços, reduzindo as reservas de CPU em 57,1% e as reservas de memória em 25%.

A estratégia adotada equilibra controle de custos, estabilidade operacional, observabilidade, alta disponibilidade e capacidade de recuperação.