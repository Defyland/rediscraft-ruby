# Threat Model

## Assets

- In-memory key/value data.
- AOF file.
- TCP server availability.

## Actors

- Trusted local user.
- Untrusted network client, explicitly out of scope.

## Trust Boundaries

The TCP listener is the main boundary. Bind to `127.0.0.1` for study runs.

## Controls

- Basic command validation.
- No shell execution from client input.

## Residual Risks

- No authentication.
- No TLS.
- No rate limiting.
- No payload size limits.
