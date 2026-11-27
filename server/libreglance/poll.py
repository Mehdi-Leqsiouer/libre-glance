import logging

from .apns import ApnsClient, ApnsResult
from .llu import LibreLinkUpClient, Reading, Session
from .store import State, Store

log = logging.getLogger(__name__)

# iOS flags the activity as stale when nothing newer arrives within this delay.
STALE_IN_S = 10 * 60


def content_state(reading: Reading, state: State, patient: str) -> dict:
    """Must match `LibreGlanceLiveActivity.ContentState` (Swift, Codable keys)."""
    return {
        "glucose": reading.value,
        "trend": reading.trend,
        "timestampMs": int(reading.timestamp.timestamp() * 1000),
        "minTarget": state.min_target,
        "maxTarget": state.max_target,
        "patient": patient or state.patient,
    }


def poll_once(llu: LibreLinkUpClient, apns: ApnsClient, store: Store, now: int) -> str:
    state = store.load()
    if not state.activity_token:
        return "no registered Live Activity"

    if state.llu_session:
        llu.session = Session(**state.llu_session)
    reading, patient = llu.latest()
    if llu.session is not None:
        store.save(llu_session=llu.session.to_dict())

    if reading.timestamp.timestamp() <= state.last_sent_ts:
        return "no new reading"

    result = apns.send_live_activity(
        state.activity_token,
        content_state(reading, state, patient),
        stale_in_s=STALE_IN_S,
        now=now,
    )
    match result:
        case ApnsResult.OK:
            store.save(last_sent_ts=reading.timestamp.timestamp(), patient=patient)
            return f"pushed {reading.value}"
        case ApnsResult.INVALID_TOKEN:
            store.save(activity_token=None)
            return "Live Activity token no longer valid, cleared"
        case _:
            return "push failed, will retry"
