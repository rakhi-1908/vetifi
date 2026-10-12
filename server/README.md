# Vetifi API

The API stores signed dataset snapshots and calculation-log idempotency records
in PostgreSQL. Startup creates the tables and seeds the initial `v14` dataset
when no dataset exists.

## Configuration

- `DATABASE_URL`: PostgreSQL SQLAlchemy URL. Docker Compose supplies a URL for
  its `db` service.
- `ADMIN_KEY`: required shared secret for dataset publishing and withdrawals,
  sent in `X-Admin-Key`.
- `ED25519_PRIVATE_KEY`: required by Docker Compose; provide a 32-byte Ed25519
  seed encoded as 64 hexadecimal characters or base64. The matching public key
  is returned with signed responses.
- `CHAOS_1`: set to `true`, `1`, `yes`, or `on` to randomly inject a tampered
  payload, invalid checksum, truncated response, or HTTP 500 on manifest and
  dataset reads.

Set `ADMIN_KEY` and `ED25519_PRIVATE_KEY` in the environment before starting
Docker Compose. For local non-container development, the API generates a
temporary signing key when `ED25519_PRIVATE_KEY` is omitted; signatures from
that key will not survive a process restart.

## Tests

Install test dependencies with `pip install -r requirements-dev.txt`, then run
`pytest test_main.py` from this directory. Tests use an in-memory SQLite
database; the deployed service uses PostgreSQL.
