import hmac
import os
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException
from google.cloud import firestore
from pydantic import BaseModel, Field

from .store import FirestoreStore, Store

app = FastAPI(title="LibreGlance")


class Registration(BaseModel):
    activity_token: str = Field(min_length=10, max_length=512)
    min_target: int = Field(ge=40, le=400)
    max_target: int = Field(ge=40, le=400)


def get_store() -> Store:
    return FirestoreStore(firestore.Client())


def require_api_key(x_api_key: Annotated[str, Header()] = "") -> None:
    expected = os.environ["API_KEY"]
    if not hmac.compare_digest(x_api_key.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="invalid API key")


# Not /healthz: Cloud Run reserves that path and answers 404 before it reaches the app.
@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/register", dependencies=[Depends(require_api_key)])
def register(body: Registration, store: Annotated[Store, Depends(get_store)]) -> dict[str, str]:
    # last_sent_ts reset: the next poll pushes the current reading to the new activity at once
    store.save(
        activity_token=body.activity_token,
        min_target=body.min_target,
        max_target=body.max_target,
        last_sent_ts=0.0,
    )
    return {"status": "registered"}
