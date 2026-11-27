import hashlib
import hmac
import os
import time
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException
from google.cloud import firestore
from pydantic import BaseModel, Field

from .store import FirestoreStore, Store

app = FastAPI(title="LibreGlance")

Token = Annotated[str | None, Field(min_length=10, max_length=512)]


class Registration(BaseModel):
    """Every field but the thresholds is optional: tokens arrive at different times."""

    min_target: int = Field(ge=40, le=400)
    max_target: int = Field(ge=40, le=400)
    activity_token: Token = None
    push_to_start_token: Token = None
    device_token: Token = None
    auto_restart: bool = True
    settings: dict[str, Any] = Field(default_factory=dict)  # AlertSettings.toJson()


class Snooze(BaseModel):
    minutes: int = Field(ge=0, le=24 * 60)  # 0 clears the snooze


def get_store() -> Store:
    return FirestoreStore(firestore.Client())


def derive_key(email: str, password: str) -> str:
    """Same formula as the app (lib/services/push_registration.dart): no separate key to manage."""
    return hashlib.sha256(f"libreglance:{email.strip().lower()}:{password}".encode()).hexdigest()


def require_api_key(x_api_key: Annotated[str, Header()] = "") -> None:
    expected = derive_key(os.environ["LLU_EMAIL"], os.environ["LLU_PASSWORD"])
    if not hmac.compare_digest(x_api_key.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="invalid key")


# Not /healthz: Cloud Run reserves that path and answers 404 before it reaches the app.
@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/register", dependencies=[Depends(require_api_key)])
def register(body: Registration, store: Annotated[Store, Depends(get_store)]) -> dict[str, str]:
    changes: dict[str, Any] = {
        "min_target": body.min_target,
        "max_target": body.max_target,
        "auto_restart": body.auto_restart,
        "settings": body.settings,
    }
    if body.device_token:
        changes["device_token"] = body.device_token
    if body.push_to_start_token:
        changes["push_to_start_token"] = body.push_to_start_token
    if body.activity_token:
        # last_sent_ts reset: the next poll pushes the current reading to the activity at once
        changes.update(live_enabled=True, activity_token=body.activity_token, last_sent_ts=0.0)
        # ponytail: a rotated token of the same activity also resets this clock (rare)
        if body.activity_token != store.load().activity_token:
            changes["activity_started_at"] = time.time()
    store.save(**changes)
    return {"status": "registered"}


@app.post("/unregister", dependencies=[Depends(require_api_key)])
def unregister(store: Annotated[Store, Depends(get_store)]) -> dict[str, str]:
    """The Dynamic Island switch is off: stop updating and restarting the Live Activity."""
    store.save(activity_token=None, push_to_start_token=None, live_enabled=False)
    return {"status": "unregistered"}


@app.post("/snooze", dependencies=[Depends(require_api_key)])
def snooze(body: Snooze, store: Annotated[Store, Depends(get_store)]) -> dict[str, float]:
    until = time.time() + body.minutes * 60 if body.minutes else 0.0
    store.save(snooze_until=until)
    return {"snooze_until": until}
