# Architectural Decisions: Vetifi Platform

## 1. Offline-First Architecture & Atomic Updates
* **Design Choice**: We use an offline-first architecture powered by a local SQLite database bundled with dataset version v14.
* **Rationale**: Veterinary professionals often operate in rural or low-connectivity clinic environments where network calls are unreliable. Packaging v14 locally ensures zero startup latency and offline availability.
* **Atomicity & Crash Safety**: Updates fetched from the server are applied via SQLite transactions (`db.transaction`). If the app crashes or gets killed mid-update, the transaction rolls back entirely, preventing partial state corruption and maintaining data integrity.

## 2. Ed25519 Cryptographic Manifest Verification
* **Design Choice**: All remote dataset updates and manifests are signed using Ed25519 public-key cryptography via the `cryptography` package.
* **Rationale**: Ed25519 provides high-performance, secure digital signatures protecting against MITM attacks or malicious payload injections. The client verifies the SHA256 hash and signature against an embedded public key before initiating local storage writes. If verification fails (e.g., during CHAOS-1 test injection), the update is safely rejected without touching existing valid data.

## 3. Calculation Logs & Zero-Network Offline Queueing
* **Design Choice**: All medication and dosage calculation logs are saved strictly to local SQLite storage first. When connectivity is detected, a background worker queues and syncs them to `/v1/calc_logs`.
* **Rationale**: Active clinical calculations must never block or fail due to network timeouts or latency spikes. Decoupling calculation execution from network synchronization guarantees 100% offline usability and ensures zero network calls happen during active calculations.

## 4. Typo-Tolerant Search & Race Condition Mitigation
* **Design Choice**: Drug search is implemented using SQLite indexing with tiered ranking (exact match $\rightarrow$ prefix match $\rightarrow$ approximate edit-distance matching) over 50,000 mock entries.
* **Rationale**: Veterinary practitioners searching under pressure need fast, forgiving results for misspelled drug names (e.g., "melokin"). To prevent stale asynchronous UI updates from overwriting newer keystrokes, each search request includes a timestamp check or cancellation token, ensuring older slow queries never replace results from a newer keystroke.

## 5. FastAPI & SQLModel Concurrency Strategy
* **Design Choice**: The backend uses FastAPI combined with SQLModel and an asynchronous database session pool backed by PostgreSQL.
* **Rationale**: Asynchronous endpoints maximize throughput for concurrent clinical queries and log uploads. PostgreSQL provides robust relational integrity, ACID compliance, and handles concurrent multi-client updates reliably across distributed veterinary clinic environments, while SQLModel bridges Pydantic V2 validation with clean ORM mappings.

## 6. Idempotency and Conflict Handling in Dataset Publishing
* **Design Choice**: Admin dataset publishing endpoints require an idempotency key and enforce strict base-version checking (returning a 409 Conflict if a stale base is provided).
* **Rationale**: In distributed clinic environments or unstable network links, administrative publish requests can be duplicated or sent out of order. Idempotency keys prevent double-publishing, and explicit version conflict checks ensure administrators never accidentally overwrite newer dataset snapshots with older revisions.