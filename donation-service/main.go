package main

import (
	"context"
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
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
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

		httpRequestsTotal.
			WithLabelValues(r.Method, r.URL.Path, status).
			Inc()

		httpRequestDurationSeconds.
			WithLabelValues(r.Method, r.URL.Path, status).
			Observe(duration)
	})
}

func main() {
	_ = godotenv.Load()

	rootContext := context.Background()

	tracerProvider, err := initTracerProvider(rootContext)
	if err != nil {
		log.Fatalf(
			"Erro ao inicializar OpenTelemetry: %v",
			err,
		)
	}

	defer func() {
		shutdownContext, cancel := context.WithTimeout(
			context.Background(),
			10*time.Second,
		)
		defer cancel()

		if err := tracerProvider.Shutdown(shutdownContext); err != nil {
			log.Printf(
				"Erro ao finalizar OpenTelemetry: %v",
				err,
			)
		}
	}()

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
		log.Fatalf(
			"Erro ao abrir conexão com banco de dados: %v",
			err,
		)
	}

	defer func() {
		if err := db.Close(); err != nil {
			log.Printf(
				"Erro ao fechar conexão com PostgreSQL: %v",
				err,
			)
		}
	}()

	if err := db.Ping(); err != nil {
		log.Fatalf(
			"Erro ao conectar ao banco de dados: %v",
			err,
		)
	}

	log.Println("Conectado ao PostgreSQL (donation-service).")

	var sqsSvc *sqs.SQS

	queueURL := os.Getenv("AWS_SQS_URL")
	region := os.Getenv("AWS_REGION")

	if queueURL != "" && region != "" {
		sess, sessionError := session.NewSession(
			&aws.Config{
				Region: aws.String(region),
			},
		)

		if sessionError != nil {
			log.Printf(
				"Falha ao criar sessão AWS: %v",
				sessionError,
			)
		} else {
			sqsSvc = sqs.New(sess)
			log.Println("Integração com AWS SQS ativada.")
		}
	} else {
		log.Println(
			"Integração com AWS SQS desativada: AWS_SQS_URL ou AWS_REGION não configurada.",
		)
	}

	app := &App{
		DB:          db,
		SqsSvc:      sqsSvc,
		SqsQueueURL: queueURL,
	}

	applicationMux := http.NewServeMux()

	applicationMux.Handle(
		"/health",
		metricsMiddleware(
			http.HandlerFunc(app.HealthHandler),
		),
	)

	applicationMux.Handle(
		"/donations",
		metricsMiddleware(
			http.HandlerFunc(app.DonationHandler),
		),
	)

	tracedApplication := otelhttp.NewHandler(
		applicationMux,
		"donation-service-http",
		otelhttp.WithSpanNameFormatter(
			func(_ string, r *http.Request) string {
				return r.Method + " " + r.URL.Path
			},
		),
	)

	rootMux := http.NewServeMux()

	// O endpoint do Prometheus fica fora do tracing para não gerar
	// milhares de traces das coletas automáticas do Prometheus.
	rootMux.Handle(
		"/metrics",
		promhttp.Handler(),
	)

	rootMux.Handle(
		"/",
		tracedApplication,
	)

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           rootMux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf(
		"donation-service rodando na porta %s com OpenTelemetry ativo",
		port,
	)

	if err := server.ListenAndServe(); err != nil &&
		err != http.ErrServerClosed {
		log.Printf(
			"Servidor HTTP encerrado com erro: %v",
			err,
		)
	}
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodGet {
		http.Error(
			w,
			`{"error":"Método não permitido"}`,
			http.StatusMethodNotAllowed,
		)
		return
	}

	w.WriteHeader(http.StatusOK)

	_, _ = w.Write(
		[]byte(
			`{"status":"ok","service":"donation-service"}`,
		),
	)
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case http.MethodPost:
		a.createDonation(w, r)

	case http.MethodGet:
		a.listDonations(w, r)

	default:
		http.Error(
			w,
			`{"error":"Método não permitido"}`,
			http.StatusMethodNotAllowed,
		)
	}
}

func (a *App) createDonation(
	w http.ResponseWriter,
	r *http.Request,
) {
	ctx, businessSpan := appTracer().Start(
		r.Context(),
		"donation.create",
		trace.WithSpanKind(trace.SpanKindInternal),
	)

	defer businessSpan.End()

	var donation Donation

	if err := json.NewDecoder(r.Body).Decode(&donation); err != nil {
		businessSpan.RecordError(err)
		businessSpan.SetStatus(
			codes.Error,
			"payload inválido",
		)

		http.Error(
			w,
			`{"error":"Payload inválido"}`,
			http.StatusBadRequest,
		)
		return
	}

	businessSpan.SetAttributes(
		attribute.Int(
			"donation.ngo_id",
			donation.NgoID,
		),
		attribute.Float64(
			"donation.amount",
			donation.Amount,
		),
	)

	if donation.NgoID <= 0 ||
		donation.Amount <= 0 ||
		donation.DonorName == "" {
		businessSpan.SetStatus(
			codes.Error,
			"campos obrigatórios inválidos",
		)

		http.Error(
			w,
			`{"error":"Campos obrigatórios inválidos"}`,
			http.StatusBadRequest,
		)
		return
	}

	donation.Status = "APPROVED"

	dbContext, dbSpan := appTracer().Start(
		ctx,
		"postgres.insert_donation",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String(
				"db.system",
				"postgresql",
			),
			attribute.String(
				"db.operation",
				"INSERT",
			),
			attribute.String(
				"db.namespace",
				"donation_db",
			),
		),
	)

	err := a.DB.QueryRowContext(
		dbContext,
		`
INSERT INTO donations (
ngo_id,
amount,
donor_name,
status
)
VALUES ($1, $2, $3, $4)
RETURNING id, created_at
`,
		donation.NgoID,
		donation.Amount,
		donation.DonorName,
		donation.Status,
	).Scan(
		&donation.ID,
		&donation.CreatedAt,
	)

	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(
			codes.Error,
			"falha ao inserir doação",
		)
		dbSpan.End()

		businessSpan.RecordError(err)
		businessSpan.SetStatus(
			codes.Error,
			"falha ao persistir doação",
		)

		log.Printf(
			"Erro ao salvar doação: %v trace_id=%s",
			err,
			traceIDFromContext(ctx),
		)

		http.Error(
			w,
			`{"error":"Erro interno"}`,
			http.StatusInternalServerError,
		)
		return
	}

	dbSpan.SetAttributes(
		attribute.Int(
			"donation.id",
			donation.ID,
		),
	)

	dbSpan.End()

	businessSpan.SetAttributes(
		attribute.Int(
			"donation.id",
			donation.ID,
		),
		attribute.String(
			"donation.status",
			donation.Status,
		),
	)

	donationsCreatedTotal.Inc()

	if a.SqsSvc != nil {
		// Mantém as informações do trace, mas não deixa o cancelamento
		// da requisição HTTP interromper o envio assíncrono ao SQS.
		eventContext := context.WithoutCancel(ctx)

		go a.sendNotificationEvent(
			eventContext,
			donation,
		)
	}

	log.Printf(
		"Doação criada com sucesso: donation_id=%d trace_id=%s",
		donation.ID,
		traceIDFromContext(ctx),
	)

	w.WriteHeader(http.StatusCreated)

	_ = json.NewEncoder(w).Encode(donation)
}

func (a *App) listDonations(
	w http.ResponseWriter,
	r *http.Request,
) {
	ctx, businessSpan := appTracer().Start(
		r.Context(),
		"donation.list",
		trace.WithSpanKind(trace.SpanKindInternal),
	)

	defer businessSpan.End()

	dbContext, dbSpan := appTracer().Start(
		ctx,
		"postgres.list_donations",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String(
				"db.system",
				"postgresql",
			),
			attribute.String(
				"db.operation",
				"SELECT",
			),
			attribute.String(
				"db.namespace",
				"donation_db",
			),
		),
	)

	rows, err := a.DB.QueryContext(
		dbContext,
		`
SELECT
id,
ngo_id,
amount,
donor_name,
status,
created_at
FROM donations
ORDER BY id DESC
`,
	)

	if err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(
			codes.Error,
			"falha ao listar doações",
		)
		dbSpan.End()

		businessSpan.RecordError(err)
		businessSpan.SetStatus(
			codes.Error,
			"falha ao consultar doações",
		)

		log.Printf(
			"Erro ao listar doações: %v trace_id=%s",
			err,
			traceIDFromContext(ctx),
		)

		http.Error(
			w,
			`{"error":"Erro interno"}`,
			http.StatusInternalServerError,
		)
		return
	}

	defer rows.Close()

	donations := []Donation{}

	for rows.Next() {
		var donation Donation

		if err := rows.Scan(
			&donation.ID,
			&donation.NgoID,
			&donation.Amount,
			&donation.DonorName,
			&donation.Status,
			&donation.CreatedAt,
		); err != nil {
			dbSpan.RecordError(err)
			dbSpan.SetStatus(
				codes.Error,
				"falha ao ler doação",
			)
			dbSpan.End()

			businessSpan.RecordError(err)
			businessSpan.SetStatus(
				codes.Error,
				"falha ao processar resultado",
			)

			log.Printf(
				"Erro ao ler linha de doação: %v trace_id=%s",
				err,
				traceIDFromContext(ctx),
			)

			http.Error(
				w,
				`{"error":"Erro interno"}`,
				http.StatusInternalServerError,
			)
			return
		}

		donations = append(
			donations,
			donation,
		)
	}

	if err := rows.Err(); err != nil {
		dbSpan.RecordError(err)
		dbSpan.SetStatus(
			codes.Error,
			"falha ao iterar doações",
		)
		dbSpan.End()

		businessSpan.RecordError(err)
		businessSpan.SetStatus(
			codes.Error,
			"falha ao iterar resultado",
		)

		log.Printf(
			"Erro ao iterar doações: %v trace_id=%s",
			err,
			traceIDFromContext(ctx),
		)

		http.Error(
			w,
			`{"error":"Erro interno"}`,
			http.StatusInternalServerError,
		)
		return
	}

	dbSpan.SetAttributes(
		attribute.Int(
			"db.response.returned_rows",
			len(donations),
		),
	)

	dbSpan.End()

	businessSpan.SetAttributes(
		attribute.Int(
			"donation.result_count",
			len(donations),
		),
	)

	log.Printf(
		"Doações listadas: count=%d trace_id=%s",
		len(donations),
		traceIDFromContext(ctx),
	)

	_ = json.NewEncoder(w).Encode(donations)
}

func (a *App) sendNotificationEvent(
	ctx context.Context,
	donation Donation,
) {
	ctx, span := appTracer().Start(
		ctx,
		"sqs.send_donation_event",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String(
				"messaging.system",
				"aws_sqs",
			),
			attribute.String(
				"messaging.destination.name",
				"solidary-donations",
			),
			attribute.String(
				"messaging.operation",
				"publish",
			),
			attribute.Int(
				"donation.id",
				donation.ID,
			),
		),
	)

	defer span.End()

	body, err := json.Marshal(donation)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(
			codes.Error,
			"falha ao serializar evento",
		)

		log.Printf(
			"Falha ao serializar evento SQS: %v trace_id=%s",
			err,
			traceIDFromContext(ctx),
		)

		sqsEventsTotal.
			WithLabelValues("serialization_error").
			Inc()

		return
	}

	carrier := propagation.MapCarrier{}

	otel.GetTextMapPropagator().Inject(
		ctx,
		carrier,
	)

	messageAttributes := make(
		map[string]*sqs.MessageAttributeValue,
		len(carrier),
	)

	for key, value := range carrier {
		messageAttributes[key] = &sqs.MessageAttributeValue{
			DataType:    aws.String("String"),
			StringValue: aws.String(value),
		}
	}

	_, err = a.SqsSvc.SendMessageWithContext(
		ctx,
		&sqs.SendMessageInput{
			MessageBody:       aws.String(string(body)),
			QueueUrl:          aws.String(a.SqsQueueURL),
			MessageAttributes: messageAttributes,
		},
	)

	if err != nil {
		span.RecordError(err)
		span.SetStatus(
			codes.Error,
			"falha ao enviar evento SQS",
		)

		log.Printf(
			"Falha ao despachar evento SQS: %v trace_id=%s",
			err,
			traceIDFromContext(ctx),
		)

		sqsEventsTotal.
			WithLabelValues("error").
			Inc()

		return
	}

	log.Printf(
		"Evento de doação enviado ao SQS: donation_id=%d trace_id=%s",
		donation.ID,
		traceIDFromContext(ctx),
	)

	sqsEventsTotal.
		WithLabelValues("success").
		Inc()
}
