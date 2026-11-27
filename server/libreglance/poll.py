import logging
import uuid
from dataclasses import replace
from datetime import UTC, datetime

from .alerts import LABELS, Kind, Settings, evaluate, message, sensor_time_left
from .apns import ApnsClient, ApnsResult
from .llu import LibreAlarms, LibreLinkUpClient, Reading, SensorWarmingUp, Session, Snapshot
from .store import State, Store

log = logging.getLogger(__name__)

# iOS flags the activity as stale when nothing newer arrives within this delay.
STALE_IN_S = 10 * 60
# iOS ends a Live Activity after 8 h: replace it a little before.
RESTART_AFTER_S = 7 * 3600 + 40 * 60
# Wait this long for the app to report the token of a remotely started activity.
START_RETRY_S = 10 * 60
# Same id as the live_activities plugin gives the activity "glucose" (UUIDv5, DNS namespace).
ACTIVITY_ID = str(uuid.uuid5(uuid.NAMESPACE_DNS, "glucose")).upper()
CRITICAL_KINDS = (Kind.URGENT_LOW, Kind.LOW)
RESTARTED = "restarted the Live Activity"


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
    # A token registered before `live_enabled` existed counts as enabled.
    live = state.live_enabled or bool(state.activity_token)
    if not (live or state.device_token):
        return "nothing registered"

    if state.llu_session:
        llu.session = Session(**state.llu_session)
    try:
        snap = llu.latest(datetime.fromtimestamp(now, UTC))
    except SensorWarmingUp:
        _save_session(llu, store)
        return "sensor warming up"
    _save_session(llu, store)

    settings = Settings.from_dict(state.settings)
    state, settings = with_libre_thresholds(state, settings, snap.alarms)
    outcomes = []
    if state.device_token:
        outcomes.append(_alerts(apns, store, state, settings, snap, now))
    if live:
        outcomes.append(_live_activity(apns, store, state, snap.reading, snap.patient, now))
    return "; ".join(outcomes)


def _save_session(llu: LibreLinkUpClient, store: Store) -> None:
    if llu.session is not None:
        store.save(llu_session=llu.session.to_dict())


def with_libre_thresholds(
    state: State, settings: Settings, alarms: LibreAlarms | None
) -> tuple[State, Settings]:
    """When the user picked LibreLink's alarm thresholds, they replace his own."""
    if not (settings.use_libre_thresholds and alarms):
        return state, settings
    return (
        replace(
            state,
            min_target=alarms.low or state.min_target,
            max_target=alarms.high or state.max_target,
        ),
        replace(settings, urgent_low=alarms.urgent_low or settings.urgent_low),
    )


def _alerts(
    apns: ApnsClient, store: Store, state: State, settings: Settings, snap: Snapshot, now: int
) -> str:
    when = datetime.fromtimestamp(now, UTC)
    fire, last_fired = evaluate(
        snap.reading,
        min_target=state.min_target,
        max_target=state.max_target,
        settings=settings,
        last_fired=state.last_fired,
        snooze_until=state.snooze_until or None,
        now=when,
        sensor_start=snap.sensor_start,
    )
    sent: list[str] = []
    for kind in fire:
        sensor_left = sensor_time_left(snap.sensor_start, settings, when)
        result = apns.send_alert(
            state.device_token or "",
            title=LABELS[kind],
            body=message(kind, snap.reading, snap.patient, when, sensor_left),
            kind=kind.value,
            critical=settings.critical_enabled and kind in CRITICAL_KINDS,
            now=now,
        )
        if result is ApnsResult.OK:
            sent.append(kind.value)
            continue
        last_fired.pop(kind.value, None)  # not delivered: try again at the next poll
        if result is ApnsResult.INVALID_TOKEN:
            store.save(device_token=None)
            break
    if last_fired != state.last_fired:
        store.save(last_fired=last_fired)
    return f"alerts {sent}" if sent else "no alert"


def _live_activity(
    apns: ApnsClient, store: Store, state: State, reading: Reading, patient: str, now: int
) -> str:
    content = content_state(reading, state, patient)
    token = state.activity_token
    can_restart = bool(state.auto_restart and state.push_to_start_token)

    near_limit = state.activity_started_at and now - state.activity_started_at >= RESTART_AFTER_S
    if token and can_restart and near_limit:
        outcome = _restart(apns, store, state, content, now)
        if outcome == RESTARTED:
            apns.end_live_activity(token, content, now=now)  # the old one is about to expire
            store.save(activity_token=None, activity_started_at=0.0)
            return outcome
        # not restarted yet (retry delay, failure): keep updating the current one

    if token:
        outcome = _update(apns, store, state, token, content, reading, patient, now)
        if outcome is not None:
            return outcome
        # token no longer valid (ended by iOS or by the user): try a restart below

    return _restart(apns, store, state, content, now) if can_restart else "no Live Activity"


def _update(
    apns: ApnsClient,
    store: Store,
    state: State,
    token: str,
    content: dict,
    reading: Reading,
    patient: str,
    now: int,
) -> str | None:
    """None when the activity token is no longer valid (and was cleared)."""
    if reading.timestamp.timestamp() <= state.last_sent_ts:
        return "no new reading"
    result = apns.send_live_activity(token, content, stale_in_s=STALE_IN_S, now=now)
    if result is ApnsResult.OK:
        store.save(last_sent_ts=reading.timestamp.timestamp(), patient=patient)
        return f"pushed {reading.value}"
    if result is ApnsResult.FAILED:
        return "push failed, will retry"
    store.save(activity_token=None)
    return None


def _restart(apns: ApnsClient, store: Store, state: State, content: dict, now: int) -> str:
    if now - state.last_start_at < START_RETRY_S:
        return "waiting for the restarted Live Activity"
    result = apns.start_live_activity(
        state.push_to_start_token or "",
        content,
        activity_id=ACTIVITY_ID,
        stale_in_s=STALE_IN_S,
        now=now,
    )
    if result is ApnsResult.OK:
        store.save(last_start_at=now, last_sent_ts=0.0)
        return RESTARTED
    if result is ApnsResult.INVALID_TOKEN:
        store.save(push_to_start_token=None)
    return "restart failed"
