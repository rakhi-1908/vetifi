from contextlib import asynccontextmanager
import base64
import hashlib
import hmac
import json
import math
import os
import random
import re
import threading
from datetime import datetime, timezone
from typing import Any, AsyncIterator

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response
from pydantic import (
    AliasChoices,
    BaseModel,
    ConfigDict,
    Field as PydanticField,
    ValidationError,
    model_validator,
)
from sqlalchemy import Column, JSON, String, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlmodel import Field, Session, SQLModel, create_engine, select
from nacl.signing import SigningKey


DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://vetifi_user:vetifi_password@localhost:5432/vetifi_db",
)
engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    connect_args={"check_same_thread": False}
    if DATABASE_URL.startswith("sqlite")
    else {},
)
_publication_lock = threading.RLock()


class Dataset(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    schema_version: int
    dataset_version: str = Field(
        sa_column=Column(String, nullable=False, unique=True, index=True)
    )
    base_version: str | None = Field(default=None, index=True)
    payload: dict[str, Any] = Field(sa_column=Column(JSON, nullable=False))
    signature: str
    idempotency_key: str | None = Field(
        default=None, sa_column=Column(String, unique=True, nullable=True)
    )
    request_hash: str | None = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class CalcLog(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    idempotency_key: str = Field(
        sa_column=Column(String, nullable=False, unique=True, index=True)
    )
    payload: dict[str, Any] = Field(sa_column=Column(JSON, nullable=False))
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class DoseRangeInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    min: float
    max: float
    unit: str


class CriRangeInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    min: float
    max: float
    unit: str = "mcg/kg/min"
    species: str | None = None


class DrugInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    id: str
    name: str
    concentration: str
    route: str
    doses: dict[str, DoseRangeInput | None]
    cri_ranges: list[CriRangeInput] = PydanticField(
        default_factory=list,
        validation_alias=AliasChoices("cri_ranges", "criRanges", "cri ranges"),
    )
    max_total_mg: float | None = PydanticField(
        default=None,
        validation_alias=AliasChoices("max_total_mg", "max total mg", "maxTotalMg"),
    )
    is_withdrawn: bool = PydanticField(
        default=False,
        validation_alias=AliasChoices("is_withdrawn", "withdrawn", "isWithdrawn"),
    )
    withdrawal_reason: str | None = None

    @model_validator(mode="after")
    def validate_entry(self) -> "DrugInput":
        if not self.id.strip() or not self.name.strip():
            raise ValueError("drug id and name must not be empty")
        if not self.concentration.strip() or not self.route.strip():
            raise ValueError("drug concentration and route must not be empty")
        if not re.fullmatch(
            r"\d+(?:[.,]\d+)?\s*(?:%|mg\s*/\s*ml|mcg\s*/\s*ml|µg\s*/\s*ml|ug\s*/\s*ml|g\s*/\s*ml)",
            self.concentration.strip(),
            re.IGNORECASE,
        ):
            raise ValueError("drug concentration must have a supported unit")
        for species, dose in self.doses.items():
            if not species.strip():
                raise ValueError("dose species must not be empty")
            if dose is not None and (
                not math.isfinite(dose.min)
                or not math.isfinite(dose.max)
                or dose.min < 0
                or dose.max < dose.min
                or not dose.unit.strip()
            ):
                raise ValueError(f"invalid dose range for species {species}")
            if dose is not None and dose.unit.strip().lower() not in {
                "mg/kg",
                "mg/kg/dose",
                "mcg/kg",
                "mcg/kg/dose",
                "ug/kg",
                "µg/kg",
            }:
                raise ValueError(f"unsupported dose unit for species {species}")
        if self.max_total_mg is not None and (
            not math.isfinite(self.max_total_mg) or self.max_total_mg <= 0
        ):
            raise ValueError("max_total_mg must be greater than zero")
        for rate in self.cri_ranges:
            if (
                not math.isfinite(rate.min)
                or not math.isfinite(rate.max)
                or rate.min < 0
                or rate.max < rate.min
                or not rate.unit.strip()
            ):
                raise ValueError("invalid CRI range")
            if rate.unit.strip().lower() not in {
                "mcg/kg/min",
                "ug/kg/min",
                "µg/kg/min",
                "mg/kg/min",
            }:
                raise ValueError("unsupported CRI unit")
        return self


class DatasetPublishInput(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    schema_version: int = PydanticField(
        validation_alias=AliasChoices("schema_version", "schema version")
    )
    dataset_version: str = PydanticField(
        validation_alias=AliasChoices("dataset_version", "dataset version")
    )
    base_version: str | None = PydanticField(
        default=None,
        validation_alias=AliasChoices("base_version", "base version"),
    )
    drugs: list[DrugInput]

    @model_validator(mode="after")
    def validate_dataset(self) -> "DatasetPublishInput":
        if self.schema_version != 2:
            raise ValueError("only schema version 2 is supported")
        if not self.dataset_version.strip():
            raise ValueError("dataset_version must not be empty")
        ids = [drug.id for drug in self.drugs]
        if len(set(ids)) != len(ids):
            raise ValueError("drug ids must be unique within a dataset")
        return self


class WithdrawInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    drug_id: str
    reason: str
    base_version: str | None = None


SEED_DATASET: dict[str, Any] = {
    "schema_version": 2,
    "dataset_version": "v14",
    "drugs": [
        {
            "id": "d001",
            "name": "Veloxamine",
            "concentration": "50 mg/mL",
            "route": "IV",
            "doses": {
                "dog": {"min": 5, "max": 10, "unit": "mg/kg"},
                "cat": {"min": 2, "max": 4, "unit": "mg/kg"},
            },
        },
        {
            "id": "d002",
            "name": "Tranzorel",
            "concentration": "1 mg/mL",
            "route": "IM",
            "doses": {
                "dog": {"min": 10, "max": 20, "unit": "mcg/kg"},
                "cat": {"min": 5, "max": 10, "unit": "mcg/kg"},
            },
        },
        {
            "id": "d003",
            "name": "Pirovane",
            "concentration": "25 mg/mL",
            "route": "PO",
            "doses": {
                "dog": {"min": 1, "max": 2, "unit": "mg/kg"},
                "cat": None,
            },
        },
        {
            "id": "d004",
            "name": "Meloquin",
            "concentration": "1.5 mg/mL",
            "route": "PO",
            "doses": {
                "dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"},
                "cat": None,
            },
        },
        {
            "id": "d005",
            "name": "Meloquin",
            "concentration": "5 mg/mL",
            "route": "SC",
            "doses": {
                "dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"},
                "cat": {"min": 0.05, "max": 0.1, "unit": "mg/kg"},
            },
        },
        {
            "id": "d006",
            "name": "Corvadil",
            "concentration": "10 mg/mL",
            "route": "IV",
            "doses": {"dog": {"min": 2, "max": 4, "unit": "mg/kg"}},
        },
        {
            "id": "d007",
            "name": "Benzaprol",
            "concentration": "10%",
            "route": "IV",
            "doses": {
                "dog": {"min": 2, "max": 5, "unit": "mg/kg"},
                "cat": {"min": 2, "max": 5, "unit": "mg/kg"},
            },
        },
        {
            "id": "d008",
            "name": "Zentrafen",
            "concentration": "100 mg/mL",
            "route": "PO",
            "max_total_mg": 400,
            "doses": {"dog": {"min": 10, "max": 15, "unit": "mg/kg"}},
        },
        {
            "id": "d009",
            "name": "Quilomid",
            "concentration": "0 mg/mL",
            "route": "IV",
            "doses": {"dog": {"min": 1, "max": 3, "unit": "mg/kg"}},
        },
        {
            "id": "d010",
            "name": "Dravexin",
            "concentration": "20 mg/mL",
            "route": "IM",
            "doses": {
                "dog": {"min": 2, "max": 4, "unit": "mg/kg"},
                "feline": {"min": 1, "max": 2, "unit": "mg/kg"},
            },
        },
    ],
}


def _signing_key() -> SigningKey:
    configured = os.getenv("ED25519_PRIVATE_KEY")
    if not configured:
        return SigningKey.generate()
    try:
        raw_key = bytes.fromhex(configured)
    except ValueError:
        try:
            raw_key = base64.b64decode(configured, validate=True)
        except ValueError as error:
            raise RuntimeError("ED25519_PRIVATE_KEY must be hex or base64") from error
    if len(raw_key) != 32:
        raise RuntimeError("ED25519_PRIVATE_KEY must decode to exactly 32 bytes")
    return SigningKey(raw_key)


SIGNING_KEY = _signing_key()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    initialize_database()
    yield


app = FastAPI(title="Vetifi Dataset API", version="1.0.0", lifespan=lifespan)


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def sign_json(value: Any) -> str:
    return base64.b64encode(SIGNING_KEY.sign(canonical_json(value)).signature).decode(
        "ascii"
    )


def get_session():
    with Session(engine) as session:
        yield session


def seed_database(session: Session) -> None:
    _lock_publication(session)
    if session.exec(select(Dataset.id).limit(1)).first() is not None:
        return
    payload = json.loads(json.dumps(SEED_DATASET))
    session.add(
        Dataset(
            schema_version=2,
            dataset_version="v14",
            base_version=None,
            payload=payload,
            signature=sign_json(payload),
        )
    )
    session.commit()


def initialize_database() -> None:
    SQLModel.metadata.create_all(engine)
    with Session(engine) as session:
        seed_database(session)


def _latest(session: Session) -> Dataset | None:
    return session.exec(
        select(Dataset).order_by(Dataset.id.desc()).limit(1)
    ).first()


def _version(session: Session, version: str) -> Dataset | None:
    return session.exec(
        select(Dataset).where(Dataset.dataset_version == version)
    ).first()


def _is_reachable(
    session: Session, target_version: str, base_version: str | None
) -> bool:
    if base_version is None:
        return False
    cursor = _version(session, target_version)
    seen: set[str] = set()
    while cursor is not None and cursor.dataset_version not in seen:
        if cursor.dataset_version == base_version:
            return True
        seen.add(cursor.dataset_version)
        if cursor.base_version is None:
            return False
        cursor = _version(session, cursor.base_version)
    return False


def _diff(base: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    base_drugs = {drug["id"]: drug for drug in base.get("drugs", [])}
    target_drugs = {drug["id"]: drug for drug in target.get("drugs", [])}
    return {
        "upsert": [
            drug
            for drug_id, drug in target_drugs.items()
            if base_drugs.get(drug_id) != drug
        ],
        "delete": sorted(base_drugs.keys() - target_drugs.keys()),
    }


def _chaos_response(payload: dict[str, Any]) -> Response | dict[str, Any]:
    if os.getenv("CHAOS_1", "").strip().lower() not in {
        "1",
        "true",
        "yes",
        "on",
    }:
        return payload

    failure = random.choice(("tamper", "checksum", "truncate", "server_error"))
    if failure == "server_error":
        return Response(status_code=500, content="CHAOS-1 injected server error")
    altered = json.loads(json.dumps(payload))
    if failure == "tamper":
        body = altered.get("payload", altered.get("delta"))
        if isinstance(body, dict) and body.get("drugs"):
            body["drugs"][0]["name"] = "TAMPERED"
        elif isinstance(body, dict) and body.get("upsert"):
            body["upsert"][0]["name"] = "TAMPERED"
        elif "latest_version" in altered:
            altered["latest_version"] = "TAMPERED"
        else:
            altered["signature"] = "TAMPERED"
    elif failure == "checksum":
        altered["sha256"] = "0" * 64
    else:
        return Response(
            content=canonical_json(altered)[: max(1, len(canonical_json(altered)) // 2)],
            media_type="application/json",
        )
    return altered


def _check_admin_key(admin_key: str | None) -> None:
    configured_key = os.getenv("ADMIN_KEY")
    if not configured_key:
        raise HTTPException(status_code=503, detail="Admin authentication is not configured")
    if admin_key is None or not hmac.compare_digest(admin_key, configured_key):
        raise HTTPException(status_code=401, detail="Invalid admin key")


def _canonical_payload(payload: dict[str, Any]) -> dict[str, Any]:
    try:
        validated = DatasetPublishInput.model_validate(payload)
    except ValidationError as error:
        raise HTTPException(
            status_code=422, detail=error.errors(include_context=False)
        ) from error
    return validated.model_dump(mode="json", exclude_none=True)


def _lock_publication(session: Session) -> None:
    if session.get_bind().dialect.name == "postgresql":
        session.exec(text("SELECT pg_advisory_xact_lock(731947205)"))


def _publish(
    session: Session,
    payload: dict[str, Any],
    idempotency_key: str | None,
) -> Dataset:
    with _publication_lock:
        return _publish_locked(session, payload, idempotency_key)


def _publish_locked(
    session: Session,
    payload: dict[str, Any],
    idempotency_key: str | None,
) -> Dataset:
    normalized = _canonical_payload(payload)
    request_hash = hashlib.sha256(canonical_json(normalized)).hexdigest()
    try:
        _lock_publication(session)
        if idempotency_key:
            previous = session.exec(
                select(Dataset).where(Dataset.idempotency_key == idempotency_key)
            ).first()
            if previous is not None:
                if previous.request_hash != request_hash:
                    raise HTTPException(
                        status_code=409,
                        detail="Idempotency key was already used for a different request",
                    )
                return previous

        latest = _latest(session)
        if latest is None:
            raise HTTPException(status_code=503, detail="Dataset seed is unavailable")
        if normalized.get("base_version") != latest.dataset_version:
            raise HTTPException(
                status_code=409,
                detail=f"base_version must be latest version {latest.dataset_version}",
            )
        if _version(session, normalized["dataset_version"]) is not None:
            raise HTTPException(status_code=409, detail="Dataset version already exists")
        row = Dataset(
            schema_version=normalized["schema_version"],
            dataset_version=normalized["dataset_version"],
            base_version=normalized["base_version"],
            payload=normalized,
            signature=sign_json(normalized),
            idempotency_key=idempotency_key,
            request_hash=request_hash if idempotency_key else None,
        )
        session.add(row)
        session.commit()
        session.refresh(row)
        return row
    except IntegrityError as error:
        session.rollback()
        raise HTTPException(
            status_code=409, detail="Dataset version or idempotency key already exists"
        ) from error
    except HTTPException:
        session.rollback()
        raise
    except SQLAlchemyError:
        session.rollback()
        raise


def _dataset_response(
    session: Session, version_row: Dataset, from_version: str | None
) -> dict[str, Any]:
    use_delta = bool(
        from_version
        and from_version != version_row.dataset_version
        and _is_reachable(session, version_row.dataset_version, from_version)
    )
    if use_delta:
        base_row = _version(session, from_version)
        response_content: dict[str, Any] = {
            "schema_version": version_row.schema_version,
            "dataset_version": version_row.dataset_version,
            "base_version": from_version,
            "delta": _diff(base_row.payload, version_row.payload),
        }
    else:
        response_content = {
            "schema_version": version_row.schema_version,
            "dataset_version": version_row.dataset_version,
            "base_version": version_row.base_version,
            "payload": version_row.payload,
        }

    serialized_payload = (
        response_content["delta"]
        if use_delta
        else response_content["payload"]
    )
    response_content["sha256"] = hashlib.sha256(
        canonical_json(serialized_payload)
    ).hexdigest()
    response_content["public_key"] = SIGNING_KEY.verify_key.encode().hex()
    response_content["signature"] = sign_json(response_content)
    return response_content


@app.get("/health")
def health(session: Session = Depends(get_session)) -> dict[str, str]:
    try:
        session.exec(text("SELECT 1"))
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="Database unavailable") from error
    return {"status": "ok"}


@app.get("/v1/manifest")
def manifest(
    response: Response,
    schema_version: int = Query(default=2, alias="schema"),
    current: str | None = None,
    if_none_match: str | None = Header(default=None, alias="If-None-Match"),
    session: Session = Depends(get_session),
):
    if schema_version != 2:
        raise HTTPException(status_code=400, detail="Unsupported schema version")
    latest = _latest(session)
    if latest is None:
        raise HTTPException(status_code=503, detail="Dataset seed is unavailable")
    if latest.schema_version != schema_version:
        raise HTTPException(status_code=404, detail="No dataset for requested schema")
    latest_payload_bytes = canonical_json(latest.payload)
    content: dict[str, Any] = {
        "schema_version": latest.schema_version,
        "latest_version": latest.dataset_version,
        "delta_available": bool(
            current
            and current != latest.dataset_version
            and _is_reachable(session, latest.dataset_version, current)
        ),
        "payload_size": len(latest_payload_bytes),
        "sha256": hashlib.sha256(latest_payload_bytes).hexdigest(),
    }
    content["public_key"] = SIGNING_KEY.verify_key.encode().hex()
    content["signature"] = sign_json(content)
    etag_value = hashlib.sha256(canonical_json(content)).hexdigest()
    etag = f'"{etag_value}"'
    response.headers["ETag"] = etag
    response.headers["Cache-Control"] = "no-cache"
    if if_none_match and etag in {
        candidate.strip() for candidate in if_none_match.split(",")
    }:
        return Response(status_code=304, headers={"ETag": etag})
    chaos_result = _chaos_response(content)
    return chaos_result


@app.get("/v1/datasets/{version}")
def get_dataset(
    version: str,
    from_version: str | None = Query(default=None, alias="from"),
    session: Session = Depends(get_session),
):
    version_row = _version(session, version)
    if version_row is None:
        raise HTTPException(status_code=404, detail="Dataset version not found")
    result = _dataset_response(session, version_row, from_version)
    return _chaos_response(result)


@app.post("/v1/admin/datasets", status_code=201)
def publish_dataset(
    payload: dict[str, Any],
    admin_key: str | None = Header(default=None, alias="X-Admin-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    session: Session = Depends(get_session),
):
    _check_admin_key(admin_key)
    row = _publish(session, payload, idempotency_key)
    return {
        "dataset_version": row.dataset_version,
        "base_version": row.base_version,
        "signature": row.signature,
        "public_key": SIGNING_KEY.verify_key.encode().hex(),
    }


@app.post("/v1/admin/withdraw", status_code=201)
def withdraw_drug(
    request: WithdrawInput,
    admin_key: str | None = Header(default=None, alias="X-Admin-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    session: Session = Depends(get_session),
):
    _check_admin_key(admin_key)
    _lock_publication(session)
    latest = _latest(session)
    if latest is None:
        raise HTTPException(status_code=503, detail="Dataset seed is unavailable")
    expected_base = request.base_version or latest.dataset_version
    if expected_base != latest.dataset_version:
        raise HTTPException(
            status_code=409,
            detail=f"base_version must be latest version {latest.dataset_version}",
        )

    payload = json.loads(json.dumps(latest.payload))
    target = next(
        (drug for drug in payload["drugs"] if drug["id"] == request.drug_id),
        None,
    )
    if target is None:
        raise HTTPException(status_code=404, detail="Drug not found")
    if not request.reason.strip():
        raise HTTPException(status_code=422, detail="Withdrawal reason is required")
    target["is_withdrawn"] = True
    target["withdrawal_reason"] = request.reason.strip()
    payload["base_version"] = latest.dataset_version
    payload["dataset_version"] = _next_version(latest.dataset_version)
    try:
        row = _publish(session, payload, idempotency_key)
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="Unable to publish withdrawal") from error
    return {
        "dataset_version": row.dataset_version,
        "base_version": row.base_version,
        "signature": row.signature,
        "public_key": SIGNING_KEY.verify_key.encode().hex(),
    }


def _next_version(version: str) -> str:
    suffix = version[1:] if version.lower().startswith("v") else version
    try:
        number = int(suffix)
    except ValueError as error:
        raise HTTPException(
            status_code=409, detail="Cannot automatically version this dataset"
        ) from error
    return f"v{number + 1}"


@app.post("/v1/calc_logs", status_code=201)
def upload_calc_log(
    payload: dict[str, Any],
    idempotency_header: str | None = Header(default=None, alias="Idempotency-Key"),
    session: Session = Depends(get_session),
):
    key = idempotency_header or payload.get("idempotency_key") or payload.get("id")
    if not isinstance(key, str) or not key.strip():
        raise HTTPException(
            status_code=422,
            detail="Provide Idempotency-Key, idempotency_key, or id",
        )
    key = key.strip()
    existing = session.exec(
        select(CalcLog).where(CalcLog.idempotency_key == key)
    ).first()
    if existing is not None:
        if canonical_json(existing.payload) != canonical_json(payload):
            raise HTTPException(
                status_code=409,
                detail="Idempotency key was already used for a different calculation",
            )
        return {"status": "duplicate", "idempotency_key": key}

    session.add(CalcLog(idempotency_key=key, payload=payload))
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        existing = session.exec(
            select(CalcLog).where(CalcLog.idempotency_key == key)
        ).first()
        if existing is None:
            raise HTTPException(status_code=409, detail="Calculation upload conflict")
        if canonical_json(existing.payload) != canonical_json(payload):
            raise HTTPException(
                status_code=409,
                detail="Idempotency key was already used for a different calculation",
            )
        return {"status": "duplicate", "idempotency_key": key}
    return {"status": "created", "idempotency_key": key}
