# BREAK_IT.md: Failure Modes & Risk Analysis

## 1. Potential Failure Modes & Protections
* **Failure Mode 1: Malicious or Tampered Server Payload**
  * *Risk*: An attacker compromises the update server or performs a Man-in-the-Middle (MITM) attack to push a modified dataset with lethal drug dosage limits[cite: 3].
  * *Protection*: Implemented strict Ed25519 cryptographic signature verification combined with SHA-256 payload hashing[cite: 3]. The client verifies the manifest signature against an embedded trusted public key before touching local storage[cite: 3]. If validation fails (or under CHAOS-1 test simulation), the payload is outright rejected[cite: 3].
  * *Test Coverage*: Covered by `sync_service_test.dart` under mock signature verification failures.

* **Failure Mode 2: App Kill Mid-Update Causing Data Corruption**
  * *Risk*: The application is forcibly closed or runs out of battery while writing a massive dataset update into SQLite.
  * *Protection*: All dataset upserts and schema migrations are wrapped inside an atomic SQLite transaction (`db.transaction`). If interrupted, the transaction completely rolls back, preserving the previous complete version v14 or v15.
  * *Test Coverage*: Atomic transaction rollback tests in `database_service_test.dart`.

* **Failure Mode 3: Race Conditions in Fast Typo-Tolerant Search**
  * *Risk*: A user types rapidly, generating multiple asynchronous search queries. A slower, earlier query completes after a newer query, causing stale results to overwrite fresh keystrokes[cite: 2].
  * *Protection*: Each query execution instance tracks a unique timestamp or token; responses from obsolete query IDs are automatically discarded upon arrival.
  * *Test Coverage*: Search concurrency unit tests validating response ordering.

## 2. Unaddressed Bug / Conscious Release Decision
* **Issue Left Unaddressed**: Extreme floating-point rounding edge cases when converting very fractional micro-doses under low body weight constraints (e.g., calculations yielding values past 3 decimal precision where syringe granularity cannot physically measure it).
* **Release Decision**: We **would release the app anyway** with a strict UI disclaimer capping display precision to readable increments (e.g., rounding down to standard clinical syringe ticks). Veterinarians are trained to cross-verify micro-dosages visually; halting execution entirely for sub-micron rounding discrepancies would cause unnecessary clinical gridlock in emergency triage settings.