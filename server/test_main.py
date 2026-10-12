from concurrent.futures import ThreadPoolExecutor
import json
import threading
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, create_engine

import main


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    test_engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    monkeypatch.setattr(main, "engine", test_engine)

    def test_session():
        with Session(test_engine) as session:
            yield session

    monkeypatch.setenv("ADMIN_KEY", "test-admin-key")
    monkeypatch.delenv("CHAOS_1", raising=False)
    monkeypatch.setattr(main, "_publication_lock", threading.RLock())
    main.app.dependency_overrides[main.get_session] = test_session
    with TestClient(main.app) as test_client:
        yield test_client
    main.app.dependency_overrides.clear()
    test_engine.dispose()


def publish_body(
    base_version: str,
    dataset_version: str,
    drugs: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": 2,
        "dataset_version": dataset_version,
        "base_version": base_version,
        "drugs": drugs
        or [
            {
                "id": "d001",
                "name": "Veloxamine",
                "concentration": "50 mg/mL",
                "route": "IV",
                "doses": {
                    "dog": {"min": 5, "max": 11, "unit": "mg/kg"},
                    "cat": {"min": 2, "max": 4, "unit": "mg/kg"},
                },
            }
        ],
    }


def test_manifest_etag_and_seeded_v14(client: TestClient):
    response = client.get("/v1/manifest?schema=2&current=v13")
    assert response.status_code == 200
    assert response.json()["latest_version"] == "v14"
    assert response.json()["delta_available"] is False
    assert response.headers["etag"]

    unchanged = client.get(
        "/v1/manifest?schema=2&current=v13",
        headers={"If-None-Match": response.headers["etag"]},
    )
    assert unchanged.status_code == 304
    assert client.get("/v1/datasets/v14").json()["payload"]["drugs"][0]["id"] == "d001"


def test_combines_multiple_version_deltas_from_original_snapshot(client: TestClient):
    first = publish_body("v14", "v15")
    publish_headers = {
        "X-Admin-Key": "test-admin-key",
        "Idempotency-Key": "publish-v15",
    }
    first_response = client.post(
        "/v1/admin/datasets",
        json=first,
        headers=publish_headers,
    )
    assert first_response.status_code == 201
    replay = client.post(
        "/v1/admin/datasets",
        json=first,
        headers=publish_headers,
    )
    assert replay.status_code == 201
    assert replay.json()["dataset_version"] == first_response.json()["dataset_version"]

    second = publish_body(
        "v15",
        "v16",
        drugs=[
            {
                "id": "d001",
                "name": "Veloxamine XR",
                "concentration": "50 mg/mL",
                "route": "IV",
                "doses": {
                    "dog": {"min": 5, "max": 11, "unit": "mg/kg"},
                    "cat": {"min": 2, "max": 4, "unit": "mg/kg"},
                },
            },
            {
                "id": "d011",
                "name": "New drug",
                "concentration": "1 mg/mL",
                "route": "IV",
                "doses": {"dog": {"min": 1, "max": 1, "unit": "mg/kg"}},
            },
        ],
    )
    second_response = client.post(
        "/v1/admin/datasets",
        json=second,
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert second_response.status_code == 201

    combined = client.get("/v1/datasets/v16?from=v14")
    assert combined.status_code == 200
    delta = combined.json()["delta"]
    assert {drug["id"] for drug in delta["upsert"]} == {"d001", "d011"}
    assert "d002" in delta["delete"]


def test_concurrent_publications_from_same_base_have_one_winner(client: TestClient):
    headers = {"X-Admin-Key": "test-admin-key"}

    def publish(version: str) -> int:
        return client.post(
            "/v1/admin/datasets",
            json=publish_body("v14", version),
            headers=headers,
        ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = list(executor.map(publish, ("v15", "v15-alt")))

    assert sorted(statuses) == [201, 409]


def test_dataset_signature_verifies_and_calc_log_is_idempotent(client: TestClient):
    response = client.get("/v1/datasets/v14")
    signed = response.json()
    signature = main.base64.b64decode(signed.pop("signature"))
    verify_key = main.SIGNING_KEY.verify_key
    verify_key.verify(main.canonical_json(signed), signature)

    calculation = {
        "idempotency_key": "calc-123",
        "drug_id": "d001",
        "dose_mg": 10,
    }
    created = client.post("/v1/calc_logs", json=calculation)
    repeated = client.post("/v1/calc_logs", json=calculation)
    assert created.status_code == 201
    assert created.json()["status"] == "created"
    assert repeated.status_code == 201
    assert repeated.json()["status"] == "duplicate"


def test_admin_withdrawal_publishes_a_signed_new_version(client: TestClient):
    response = client.post(
        "/v1/admin/withdraw",
        json={"drug_id": "d001", "reason": "Safety review", "base_version": "v14"},
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 201
    assert response.json()["dataset_version"] == "v15"

    latest = client.get("/v1/datasets/v15").json()
    withdrawn = next(
        drug for drug in latest["payload"]["drugs"] if drug["id"] == "d001"
    )
    assert withdrawn["is_withdrawn"] is True
    assert withdrawn["withdrawal_reason"] == "Safety review"


def test_chaos_mode_injects_tampering_checksum_truncation_and_errors(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setenv("CHAOS_1", "true")
    monkeypatch.setattr(main.random, "choice", lambda _: "tamper")
    tampered = client.get("/v1/datasets/v14").json()
    assert tampered["payload"]["drugs"][0]["name"] == "TAMPERED"

    monkeypatch.setattr(main.random, "choice", lambda _: "checksum")
    bad_checksum = client.get("/v1/datasets/v14").json()
    assert bad_checksum["sha256"] == "0" * 64

    monkeypatch.setattr(main.random, "choice", lambda _: "truncate")
    truncated = client.get("/v1/datasets/v14")
    with pytest.raises(json.JSONDecodeError):
        truncated.json()

    monkeypatch.setattr(main.random, "choice", lambda _: "server_error")
    assert client.get("/v1/datasets/v14").status_code == 500
