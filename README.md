# Vetifi: Decentralized Electoral Oversight & Veterinary Clinical Platform

Vetifi is an offline-first veterinary clinical decision-support and electoral oversight monitoring system. It ensures high availability in low-connectivity rural clinic environments through robust local data caching and atomic updates.

## Architecture
* **Backend**: FastAPI, SQLModel, PostgreSQL running via Docker Compose.
* **Mobile Client**: Flutter (Offline-first architecture using local SQLite storage).
* **Security**: Ed25519 public-key cryptography for manifest verification and secure updates.

## Flutter API configuration

The app runs its search and dose calculations from the bundled/local dataset.
To enable dataset and calculation-log sync, provide the backend base URL when
building or running the app:

```bash
flutter run --dart-define=VETIFI_API_BASE_URL=https://your-api-host
```

Without that define, the app targets `http://10.0.2.2:8000` on Android
emulators and `http://localhost:8000` on other platforms for local development.
Use an HTTPS URL for deployed builds. The app starts connectivity-triggered
background sync and also exposes a manual sync action and local calculation
outbox from the app bar.

## Quick Start (Docker Backend)
1. Ensure Docker Desktop and WSL2 are running.
2. Navigate to the project root directory.
3. Run the following command to spin up PostgreSQL and the FastAPI server:
   ```bash
   docker compose up --build -d