package main

import (
	"context"
	"fmt"
	"os"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

const instrumentationName = "solidarytech/donation-service"

func initTracerProvider(ctx context.Context) (*sdktrace.TracerProvider, error) {
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("criar exporter OTLP/HTTP: %w", err)
	}

	res, err := resource.New(
		ctx,
		resource.WithAttributes(
			attribute.String(
				"service.name",
				envOrDefault("OTEL_SERVICE_NAME", "donation-service"),
			),
			attribute.String(
				"service.namespace",
				"solidarytech",
			),
			attribute.String(
				"service.version",
				envOrDefault("SERVICE_VERSION", "development"),
			),
			attribute.String(
				"deployment.environment.name",
				envOrDefault("OTEL_DEPLOYMENT_ENVIRONMENT", "production"),
			),
			attribute.String(
				"cloud.provider",
				"aws",
			),
			attribute.String(
				"cloud.platform",
				"aws_eks",
			),
			attribute.String(
				"k8s.cluster.name",
				"solidarytech-production",
			),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("criar resource OpenTelemetry: %w", err)
	}

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(
			sdktrace.ParentBased(
				sdktrace.AlwaysSample(),
			),
		),
	)

	otel.SetTracerProvider(provider)

	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{},
			propagation.Baggage{},
		),
	)

	return provider, nil
}

func appTracer() trace.Tracer {
	return otel.Tracer(instrumentationName)
}

func traceIDFromContext(ctx context.Context) string {
	spanContext := trace.SpanContextFromContext(ctx)

	if !spanContext.IsValid() {
		return "unavailable"
	}

	return spanContext.TraceID().String()
}

func envOrDefault(name, fallback string) string {
	value := os.Getenv(name)

	if value == "" {
		return fallback
	}

	return value
}
