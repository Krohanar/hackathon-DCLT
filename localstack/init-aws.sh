#!/bin/sh
set -e

echo "Criando fila SQS solidary-donations..."
awslocal sqs create-queue \
  --queue-name solidary-donations || true

echo "Criando tabela DynamoDB SolidaryTechVolunteers..."
awslocal dynamodb create-table \
  --table-name SolidaryTechVolunteers \
  --attribute-definitions AttributeName=volunteer_id,AttributeType=S \
  --key-schema AttributeName=volunteer_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST || true

echo "Recursos locais AWS criados com sucesso."
