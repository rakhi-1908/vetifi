# Vetifi: Decentralized Electoral Oversight & Veterinary Clinical Platform

Vetifi is an offline-first veterinary clinical decision-support and electoral oversight monitoring system. It ensures high availability in low-connectivity rural clinic environments through robust local data caching and atomic updates.

## Architecture
* **Backend**: FastAPI, SQLModel, PostgreSQL running via Docker Compose.
* **Mobile Client**: Flutter (Offline-first architecture using local SQLite storage).
* **Security**: Ed25519 public-key cryptography for manifest verification and secure updates.

## Quick Start (Docker Backend)
1. Ensure Docker Desktop and WSL2 are running.
2. Navigate to the project root directory.
3. Run the following command to spin up PostgreSQL and the FastAPI server:
   ```bash
   docker compose up --build -d