# ADR-011: Technology stack

- **Status:** Accepted
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** PROG

## Context
Performance and very large data volumes are priorities; the team uses VS Code.

## Decision
Java 21 with Spring Boot 3 for core services (virtual threads, JDBC batching, mature workflow-engine SDKs); PostgreSQL 16; Flyway migrations; pgTAP and Testcontainers for tests; GitHub Actions for CI. Python only for AI services and analysis tooling, behind internal APIs.

## Alternatives considered
- Python for all services: faster to write, weaker for CPU-bound parallel work.
- TypeScript or .NET.

## Consequences
Strong performance and ecosystem fit; two languages to maintain with a clear boundary. Workflow engine (Temporal or Camunda) to be chosen in a later ADR.
