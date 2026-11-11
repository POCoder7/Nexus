# ADR-034: Observability — structured logs, Micrometer metrics, OpenTelemetry traces

- **Status:** Accepted (repository owner, 2026-11-11). Dependencies approved in the Phase 9 build plan
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG (NFRs)

## Context
Every phase defined metrics and alerts. `spring-boot-starter-actuator` exists; nothing else is configured, and actuator
`metrics` is exposed without authentication (D-20). The platform's backends are not chosen (OD-15a).

## Decision
- Logs: Spring Boot structured logging (JSON, ECS) to stdout with correlation, actor and request ids; a filter removes personal data.
- Metrics: Micrometer with the Prometheus registry; `nexus.*` names as defined in the phase LLDs.
- Traces: Micrometer Tracing with the OpenTelemetry bridge, OTLP export to the platform's collector.
- Actuator: `health` (liveness, readiness groups) on the management port; `prometheus` only to the scraper network.

## Alternatives considered
- **Vendor agent (bytecode instrumentation):** less code, but ties Nexus to one vendor and is harder to control for personal data.
- **Logs only:** no latency histograms or cross-service traces.

## Consequences
- Dependencies (all Spring Boot-managed): `micrometer-registry-prometheus`, `micrometer-tracing-bridge-otel`, `opentelemetry-exporter-otlp`; approved in the Phase 9 plan.
- Backends are configuration per environment.
