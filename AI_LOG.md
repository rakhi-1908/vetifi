# AI_LOG.md: AI Usage & Audit Log

## 1. AI Tool Usage Breakdown
* **Tools Used**: Gemini 1.5 Pro / Claude 3.5 Sonnet / GitHub Copilot via IDE integration.
* **Estimated AI Generation**: ~65% of boilerplate setup, FastAPI routing templates, Flutter UI scaffolds, and unit test structures were AI-assisted. 35% (core architecture decisions, SQLite atomic transactions, Ed25519 signature binding, and edge-case validation rules) was manually engineered and debugged.

## 2. Instances Where AI Was Wrong or Unsafe
* **Instance 1: Unsafe Database Update Logic (Code Review Part G / Function 2)**
  * *AI Prompt*: "Write a Flutter function to apply JSON dataset updates to SQLite."
  * *AI Response*: Suggested clearing the entire `drugs` table first using `db.delete('drugs')`, then looping through upserts inside a non-transactional loop.
  * *Correction*: This was completely unsafe because if the app crashed halfway through the loop, the local database would be left empty (data loss). Replaced with an atomic transaction block that preserves old data until all rows are successfully processed.

* **Instance 2: Flawed FastAPI Admin Endpoint Concurrency Handling**
  * *AI Prompt*: "Generate a FastAPI endpoint to publish new dataset versions."
  * *AI Response*: Suggested simple auto-incrementing integer versioning without checking base version lineage or enforcing idempotency keys.
  * *Correction*: In distributed environments, this risks race conditions and conflicting concurrent publishes. Implemented explicit 409 Conflict checks against base versions and idempotency key validation.

## 3. Changed Decision
* **Initial Approach**: Initially planned to handle offline calculation sync via standard background service packages without persistent queueing tables.
* **Why We Changed**: Realized that if the app process died while waiting for network connectivity, pending logs would be lost from memory. Switched to a dedicated local SQLite outbox table (`calc_logs` queue) ensuring durability across app restarts until successfully acknowledged by `/v1/calc_logs`.