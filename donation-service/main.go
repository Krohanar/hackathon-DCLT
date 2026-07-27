package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
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

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "solidarytech",
			Subsystem: "donation_service",
			Name:      "http_requests_total",
			Help:      "Total de requisicoes HTTP recebidas pelo donation-service.",
		},
		[]string{"method", "path", "status"},
	)

	httpRequestDurationSeconds = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: "solidarytech",
			Subsystem: "donation_service",
			Name:      "http_request_duration_seconds",
			Help:      "Duracao das requisicoes HTTP recebidas pelo donation-service em segundos.",
			Buckets:   []float64{0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		},
		[]string{"method", "path", "status"},
	)

	donationsCreatedTotal = promauto.NewCounter(
		prometheus.CounterOpts{
			Namespace: "solidarytech",
			Subsystem: "donation_service",
			Name:      "donations_created_total",
			Help:      "Total de doacoes criadas com sucesso.",
		},
	)

	sqsEventsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "solidarytech",
			Subsystem: "donation_service",
			Name:      "sqs_events_total",
			Help:      "Total de eventos de doacao enviados para SQS, por status.",
		},
		[]string{"status"},
	)
)

type metricsResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func newMetricsResponseWriter(w http.ResponseWriter) *metricsResponseWriter {
	return &metricsResponseWriter{
		ResponseWriter: w,
		statusCode:     http.StatusOK,
	}
}

func (w *metricsResponseWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		recorder := newMetricsResponseWriter(w)
		next.ServeHTTP(recorder, r)

		duration := time.Since(start).Seconds()
		status := strconv.Itoa(recorder.statusCode)

		httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, status).Inc()
		httpRequestDurationSeconds.WithLabelValues(r.Method, r.URL.Path, status).Observe(duration)
	})
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

	if queueURL != "" && region != "" {
		sess, err := session.NewSession(&aws.Config{Region: aws.String(region)})
		if err != nil {
			log.Printf("Falha ao criar sessão AWS: %v", err)
		} else {
			sqsSvc = sqs.New(sess)
			log.Println("Integração com AWS SQS ativada.")
		}
	} else {
		log.Println("Integração com AWS SQS desativada: AWS_SQS_URL ou AWS_REGION não configurada.")
	}

	app := &App{
		DB:          db,
		SqsSvc:      sqsSvc,
		SqsQueueURL: queueURL,
	}

	mux := http.NewServeMux()

	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/health", metricsMiddleware(http.HandlerFunc(app.HealthHandler)))
	mux.Handle("/donations", metricsMiddleware(http.HandlerFunc(app.DonationHandler)))

	log.Printf("donation-service rodando na porta %s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
		return
	}

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"ok","service":"donation-service"}`))
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case http.MethodPost:
		a.createDonation(w, r)
	case http.MethodGet:
		a.listDonations(w, r)
	default:
		http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
	}
}

func (a *App) createDonation(w http.ResponseWriter, r *http.Request) {
	var d Donation

	if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
		http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
		return
	}

	if d.NgoID <= 0 || d.Amount <= 0 || d.DonorName == "" {
		http.Error(w, `{"error":"Campos obrigatórios inválidos"}`, http.StatusBadRequest)
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

	donationsCreatedTotal.Inc()

	if a.SqsSvc != nil {
		go a.sendNotificationEvent(d)
	}

	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(d)
}

func (a *App) listDonations(w http.ResponseWriter, r *http.Request) {
	rows, err := a.DB.Query("SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
	if err != nil {
		log.Printf("Erro ao listar doações: %v", err)
		http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	donations := []Donation{}

	for rows.Next() {
		var d Donation

		if err := rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt); err != nil {
			log.Printf("Erro ao ler linha de doação: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}

		donations = append(donations, d)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Erro ao iterar doações: %v", err)
		http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
		return
	}

	_ = json.NewEncoder(w).Encode(donations)
}

func (a *App) sendNotificationEvent(d Donation) {
	body, err := json.Marshal(d)
	if err != nil {
		log.Printf("Falha ao serializar evento SQS: %v", err)
		sqsEventsTotal.WithLabelValues("serialization_error").Inc()
		return
	}

	_, err = a.SqsSvc.SendMessage(&sqs.SendMessageInput{
		MessageBody: aws.String(string(body)),
		QueueUrl:    aws.String(a.SqsQueueURL),
	})

	if err != nil {
		log.Printf("Falha ao despachar evento SQS: %v", err)
		sqsEventsTotal.WithLabelValues("error").Inc()
		return
	}

	log.Printf("Evento de doação enviado ao SQS: donation_id=%d", d.ID)
	sqsEventsTotal.WithLabelValues("success").Inc()
}
