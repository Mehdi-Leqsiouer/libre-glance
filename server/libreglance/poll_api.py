"""Private Cloud Run service: Cloud Scheduler calls POST /poll every minute (IAM-protected).

Called every minute, the instance stays warm, so clients (and the APNs token) are reused.
"""

import logging
import os
import time
from functools import lru_cache

import httpx
from fastapi import FastAPI, HTTPException
from google.cloud import firestore

from .apns import ApnsClient
from .llu import LibreLinkUpClient, LibreLinkUpError
from .poll import poll_once
from .store import FirestoreStore, Store

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("libreglance.poll")
app = FastAPI(title="LibreGlance poll")


@lru_cache(maxsize=1)
def _deps() -> tuple[LibreLinkUpClient, ApnsClient, Store]:
    http = httpx.Client(http2=True, timeout=15)
    llu = LibreLinkUpClient(http, os.environ["LLU_EMAIL"], os.environ["LLU_PASSWORD"])
    apns = ApnsClient(
        http,
        key_pem=os.environ["APNS_KEY_P8"],
        key_id=os.environ["APNS_KEY_ID"],
        team_id=os.environ["APNS_TEAM_ID"],
        bundle_id=os.environ["APNS_BUNDLE_ID"],
    )
    return llu, apns, FirestoreStore(firestore.Client())


@app.post("/poll", responses={502: {"description": "LibreLinkUp or APNs call failed"}})
def poll() -> dict[str, str]:
    llu, apns, store = _deps()
    try:
        outcome = poll_once(llu, apns, store, int(time.time()))
    except (LibreLinkUpError, httpx.HTTPError) as exc:
        log.exception("poll failed")
        raise HTTPException(status_code=502, detail="poll failed") from exc
    log.info(outcome)
    return {"outcome": outcome}
