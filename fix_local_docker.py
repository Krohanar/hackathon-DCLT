from pathlib import Path

def write(path, content):
    file_path = Path(path)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_text(content.strip() + "\n", encoding="utf-8")
    print(f"OK: {path}")

write("db/init/01-create-databases.sql", r"""
CREATE DATABASE ngo_db;
CREATE DATABASE donation_db;
""")

write("db/init/02-init-ngo-db.sql", r"""
\connect ngo_db;

CREATE TABLE IF NOT EXISTS ngos (
    id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    cause VARCHAR(100) NOT NULL,
    city VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO ngos (name, email, cause, city) VALUES
('Anjos de Patas', 'contato@anjosdepatas.org', 'Proteção Animal', 'Osasco'),
('Educa Mais', 'info@educamais.org', 'Educação', 'São Paulo')
ON CONFLICT (email) DO NOTHING;
""")

write("db/init/03-init-donation-db.sql", r"""
\connect donation_db;

CREATE TABLE IF NOT EXISTS donations (
    id SERIAL PRIMARY KEY,
    ngo_id INT NOT NULL,
    amount NUMERIC(10, 2) NOT NULL,
    donor_name VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
""")

write("localstack/init-aws.sh", r"""
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
""")

write("ngo-service/requirements.txt", r"""
Flask==2.2.2
Werkzeug==2.2.3
psycopg2-binary==2.9.5
gunicorn==20.1.0
python-dotenv==0.21.0
""")

write("volunteer-service/requirements.txt", r"""
Flask==2.2.2
Werkzeug==2.2.3
gunicorn==20.1.0
python-dotenv==0.21.0
boto3==1.26.50
""")

write("donation-service/go.mod", r"""
module donation-service

go 1.21

require (
	github.com/aws/aws-sdk-go v1.51.10
	github.com/jackc/pgx/v4 v4.18.3
	github.com/joho/godotenv v1.5.1
)
""")

write("volunteer-service/app.py", r'''
import os
import sys
import uuid
import time
import logging

import boto3
from boto3.dynamodb.conditions import Attr
from flask import Flask, request, jsonify
from dotenv import load_dotenv

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
log = logging.getLogger(__name__)

load_dotenv()

app = Flask(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL")
DYNAMODB_TABLE = os.getenv("AWS_DYNAMODB_TABLE")

if not DYNAMODB_TABLE:
    log.critical("Erro: AWS_DYNAMODB_TABLE não definida.")
    sys.exit(1)

try:
    dynamodb_kwargs = {
        "region_name": AWS_REGION,
    }

    if AWS_ENDPOINT_URL:
        dynamodb_kwargs["endpoint_url"] = AWS_ENDPOINT_URL

    dynamodb = boto3.resource("dynamodb", **dynamodb_kwargs)
    table = dynamodb.Table(DYNAMODB_TABLE)
    log.info(f"Conectado à tabela DynamoDB: {DYNAMODB_TABLE}")
except Exception as e:
    log.critical(f"Falha ao conectar no DynamoDB: {e}")
    sys.exit(1)


@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "volunteer-service"})


@app.route("/volunteers", methods=["POST"])
def register_volunteer():
    data = request.get_json()

    if not data or not all(k in data for k in ("name", "email", "ngo_id")):
        return jsonify({"error": "Campos obrigatórios ausentes"}), 400

    volunteer_id = str(uuid.uuid4())

    item = {
        "volunteer_id": volunteer_id,
        "name": data["name"],
        "email": data["email"],
        "ngo_id": int(data["ngo_id"]),
        "registered_at": str(int(time.time())),
    }

    try:
        table.put_item(Item=item)
        return jsonify(item), 201
    except Exception as e:
        log.error(f"Erro ao salvar voluntário no DynamoDB: {e}")
        return jsonify({"error": "Erro interno ao processar dados"}), 500


@app.route("/volunteers/<int:ngo_id>", methods=["GET"])
def get_volunteers_by_ngo(ngo_id):
    try:
        response = table.scan(
            FilterExpression=Attr("ngo_id").eq(ngo_id)
        )

        return jsonify(response.get("Items", [])), 200
    except Exception as e:
        log.error(f"Erro ao buscar dados no DynamoDB: {e}")
        return jsonify({"error": "Erro interno"}), 500


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8083))
    app.run(host="0.0.0.0", port=port)
''')

write("donation-service/main.go", r'''
package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
)

type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type App struct {
	DB          *sql.DB
	SqsSvc      *sqs.SQS
	SqsQueueURL string
}

func main() {
	_ = godotenv.Load()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL é obrigatória")
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		log.Fatalf("Erro ao abrir conexão com banco de dados: %v", err)
	}

	if err := db.Ping(); err != nil {
		log.Fatalf("Erro ao conectar ao banco de dados: %v", err)
	}

	log.Println("Conectado ao PostgreSQL (donation-service).")

	var sqsSvc *sqs.SQS

	queueURL := os.Getenv("AWS_SQS_URL")
	region := os.Getenv("AWS_REGION")
	endpointURL := os.Getenv("AWS_ENDPOINT_URL")

	if queueURL != "" && region != "" {
		awsConfig := aws.NewConfig().WithRegion(region)

		if endpointURL != "" {
			awsConfig = awsConfig.WithEndpoint(endpointURL)
		}

		sess, err := session.NewSession(awsConfig)
		if err != nil {
			log.Printf("Falha ao criar sessão AWS: %v", err)
		} else {
			sqsSvc = sqs.New(sess)
			log.Println("Integração com AWS SQS ativada.")
		}
	} else {
		log.Println("AWS_SQS_URL ou AWS_REGION não definidos. SQS desativado.")
	}

	app := &App{
		DB:          db,
		SqsSvc:      sqsSvc,
		SqsQueueURL: queueURL,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.HealthHandler)
	mux.HandleFunc("/donations", app.DonationHandler)

	log.Printf("donation-service rodando na porta %s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"ok","service":"donation-service"}`))
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodPost {
		var d Donation

		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
			return
		}

		d.Status = "APPROVED"

		err := a.DB.QueryRow(
			"INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
			d.NgoID,
			d.Amount,
			d.DonorName,
			d.Status,
		).Scan(&d.ID, &d.CreatedAt)

		if err != nil {
			log.Printf("Erro ao salvar doação: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}

		if a.SqsSvc != nil {
			go a.sendNotificationEvent(d)
		}

		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(d)
		return
	}

	if r.Method == http.MethodGet {
		rows, err := a.DB.Query("SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
		if err != nil {
			log.Printf("Erro ao buscar doações: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		donations := []Donation{}

		for rows.Next() {
			var d Donation

			if err := rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt); err != nil {
				log.Printf("Erro ao ler doação: %v", err)
				http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
				return
			}

			donations = append(donations, d)
		}

		_ = json.NewEncoder(w).Encode(donations)
		return
	}

	http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
}

func (a *App) sendNotificationEvent(d Donation) {
	body, _ := json.Marshal(d)

	_, err := a.SqsSvc.SendMessage(&sqs.SendMessageInput{
		MessageBody: aws.String(string(body)),
		QueueUrl:    aws.String(a.SqsQueueURL),
	})

	if err != nil {
		log.Printf("Falha ao despachar evento SQS: %v", err)
		return
	}

	log.Printf("Evento de doação enviado ao SQS: donation_id=%d", d.ID)
}
''')

write("ngo-service/Dockerfile", r"""
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER appuser

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/health')" || exit 1

CMD gunicorn --bind 0.0.0.0:${PORT:-8081} --workers 2 --threads 2 --timeout 30 app:app
""")

write("donation-service/Dockerfile", r"""
FROM golang:1.21-alpine AS builder

WORKDIR /src

COPY go.mod .

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/donation-service .

FROM alpine:3.20

RUN apk add --no-cache ca-certificates wget \
    && addgroup -S appgroup \
    && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=builder /out/donation-service /app/donation-service

USER appuser

EXPOSE 8082

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8082/health || exit 1

CMD ["/app/donation-service"]
""")

write("volunteer-service/Dockerfile", r"""
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER appuser

EXPOSE 8083

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8083/health')" || exit 1

CMD gunicorn --bind 0.0.0.0:${PORT:-8083} --workers 2 --threads 2 --timeout 30 app:app
""")

write("ngo-service/.dockerignore", r"""
__pycache__/
*.pyc
.env
.venv/
venv/
.pytest_cache/
""")

write("donation-service/.dockerignore", r"""
.env
tmp/
bin/
*.test
""")

write("volunteer-service/.dockerignore", r"""
__pycache__/
*.pyc
.env
.venv/
venv/
.pytest_cache/
""")

write("docker-compose.yml", r"""
services:
  postgres:
    image: postgres:16-alpine
    container_name: solidarytech-postgres
    environment:
      POSTGRES_USER: solidary
      POSTGRES_PASSWORD: solidary
      POSTGRES_DB: solidary
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U solidary"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - solidarytech

  localstack:
    image: localstack/localstack:latest
    container_name: solidarytech-localstack
    environment:
      SERVICES: sqs,dynamodb
      AWS_DEFAULT_REGION: us-east-1
      DEBUG: "0"
    ports:
      - "4566:4566"
    volumes:
      - ./localstack/init-aws.sh:/etc/localstack/init/ready.d/init-aws.sh
      - localstack_data:/var/lib/localstack
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - solidarytech

  ngo-service:
    build:
      context: ./ngo-service
    container_name: solidarytech-ngo-service
    environment:
      PORT: "8081"
      DATABASE_URL: postgresql://solidary:solidary@postgres:5432/ngo_db
    ports:
      - "8081:8081"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - solidarytech

  donation-service:
    build:
      context: ./donation-service
    container_name: solidarytech-donation-service
    environment:
      PORT: "8082"
      DATABASE_URL: postgres://solidary:solidary@postgres:5432/donation_db?sslmode=disable
      AWS_REGION: us-east-1
      AWS_ENDPOINT_URL: http://localstack:4566
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_SQS_URL: http://localstack:4566/000000000000/solidary-donations
    ports:
      - "8082:8082"
    depends_on:
      postgres:
        condition: service_healthy
      localstack:
        condition: service_started
    networks:
      - solidarytech

  volunteer-service:
    build:
      context: ./volunteer-service
    container_name: solidarytech-volunteer-service
    environment:
      PORT: "8083"
      AWS_REGION: us-east-1
      AWS_ENDPOINT_URL: http://localstack:4566
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_DYNAMODB_TABLE: SolidaryTechVolunteers
    ports:
      - "8083:8083"
    depends_on:
      localstack:
        condition: service_started
    networks:
      - solidarytech

volumes:
  postgres_data:
  localstack_data:

networks:
  solidarytech:
    driver: bridge
""")
