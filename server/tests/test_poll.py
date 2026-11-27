import hashlib
import uuid
from datetime import UTC, datetime

from fakes import NOW, FakeApns, FakeLlu, FakeStore, reading

from libreglance.apns import ApnsResult
from libreglance.llu import Reading
from libreglance.poll import (
    ACTIVITY_ID,
    RESTART_AFTER_S,
    START_RETRY_S,
    content_state,
    poll_once,
)
from libreglance.store import State

TOKEN = "t" * 20


def poll(state: State, current=None, apns=None, now=NOW):
    store = FakeStore(state)
    apns = apns or FakeApns()
    outcome = poll_once(FakeLlu(current or reading(now=now)), apns, store, now)
    return outcome, apns, store.state


def test_content_state_matches_the_swift_keys():
    r = Reading(126, 4, datetime(2026, 11, 23, 15, 5, 9, tzinfo=UTC))
    state = State(min_target=70, max_target=180, patient="Ada")
    assert content_state(r, state, "") == {
        "glucose": 126,
        "trend": 4,
        "timestampMs": 1_795_446_309_000,
        "minTarget": 70,
        "maxTarget": 180,
        "patient": "Ada",
    }


def test_activity_id_is_the_uuid5_the_plugin_uses_for_glucose():
    # Step by step port of LiveActivitiesPlugin.uuid5(namespace:name:) (Swift)
    namespace = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    digest = bytearray(hashlib.sha1(namespace.bytes + b"glucose").digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    assert str(uuid.UUID(bytes=bytes(digest))).upper() == ACTIVITY_ID


def test_nothing_registered_does_nothing():
    outcome, apns, _ = poll(State())
    assert outcome == "nothing registered"
    assert apns.calls == []


def test_a_token_registered_before_live_enabled_existed_is_still_updated():
    # State written by the previous server version: a token, no live_enabled field
    outcome, apns, _ = poll(State(activity_token=TOKEN))
    assert outcome == "pushed 126"
    assert apns.names() == ["send_live_activity"]


def test_live_activity_update_then_no_duplicate_push():
    state = State(live_enabled=True, activity_token=TOKEN)
    outcome, apns, state = poll(state)
    assert outcome == "pushed 126"
    assert state.last_sent_ts == NOW
    outcome, apns2, _ = poll(state, apns=FakeApns())
    assert outcome == "no new reading"
    assert apns2.calls == []


def test_failed_update_is_retried_and_not_marked_sent():
    state = State(live_enabled=True, activity_token=TOKEN)
    outcome, _, state = poll(state, apns=FakeApns(send_live_activity=ApnsResult.FAILED))
    assert "retry" in outcome
    assert state.last_sent_ts == 0


def test_invalid_activity_token_triggers_an_automatic_restart():
    state = State(live_enabled=True, activity_token=TOKEN, push_to_start_token="p" * 20)
    outcome, apns, state = poll(state, apns=FakeApns(send_live_activity=ApnsResult.INVALID_TOKEN))
    assert apns.names() == ["send_live_activity", "start_live_activity"]
    assert apns.calls[1][1]["activity_id"] == ACTIVITY_ID
    assert state.activity_token is None
    assert state.last_start_at == NOW
    assert outcome == "restarted the Live Activity"


def test_no_restart_when_disabled_or_without_a_push_to_start_token():
    base = dict(live_enabled=True, activity_token=TOKEN)
    for extra in ({"push_to_start_token": "p" * 20, "auto_restart": False}, {}):
        _, apns, _ = poll(
            State(**base, **extra), apns=FakeApns(send_live_activity=ApnsResult.INVALID_TOKEN)
        )
        assert "start_live_activity" not in apns.names()


def test_restart_is_not_repeated_within_the_retry_delay():
    state = State(live_enabled=True, push_to_start_token="p" * 20, last_start_at=NOW - 60)
    outcome, apns, _ = poll(state)
    assert "waiting" in outcome
    assert apns.calls == []
    state = State(
        live_enabled=True, push_to_start_token="p" * 20, last_start_at=NOW - START_RETRY_S
    )
    assert poll(state)[0] == "restarted the Live Activity"


def test_activity_is_replaced_before_the_8_hour_limit():
    state = State(
        live_enabled=True,
        activity_token=TOKEN,
        push_to_start_token="p" * 20,
        activity_started_at=NOW - RESTART_AFTER_S,
    )
    outcome, apns, state = poll(state)
    assert apns.names() == ["start_live_activity", "end_live_activity"]
    assert state.activity_token is None
    assert outcome == "restarted the Live Activity"


def test_a_young_activity_is_just_updated():
    state = State(
        live_enabled=True,
        activity_token=TOKEN,
        push_to_start_token="p" * 20,
        activity_started_at=NOW - 3600,
    )
    assert poll(state)[1].names() == ["send_live_activity"]


def test_low_reading_sends_an_alert_once_until_the_cooldown():
    state = State(device_token=TOKEN)
    outcome, apns, state = poll(state, current=reading(60))
    assert apns.names() == ["send_alert"]
    assert apns.calls[0][1]["kind"] == "low"
    assert "low" in state.last_fired

    _, apns, _ = poll(state, current=reading(60), apns=FakeApns())
    assert apns.calls == []


def test_undelivered_alert_is_retried_at_the_next_poll():
    state = State(device_token=TOKEN)
    _, _, state = poll(state, current=reading(60), apns=FakeApns(send_alert=ApnsResult.FAILED))
    assert state.last_fired == {}
    _, apns, _ = poll(state, current=reading(60), apns=FakeApns())
    assert apns.names() == ["send_alert"]


def test_invalid_device_token_is_cleared():
    state = State(device_token=TOKEN)
    _, _, state = poll(
        state, current=reading(60), apns=FakeApns(send_alert=ApnsResult.INVALID_TOKEN)
    )
    assert state.device_token is None


def test_alert_settings_and_critical_mode_come_from_the_registration():
    state = State(device_token=TOKEN, settings={"lowEnabled": False})
    assert poll(state, current=reading(60))[1].calls == []

    state = State(device_token=TOKEN, settings={"criticalEnabled": True})
    _, apns, _ = poll(state, current=reading(50))
    assert apns.calls[0][1]["kind"] == "urgentLow"
    assert apns.calls[0][1]["critical"] is True

    state = State(device_token=TOKEN, settings={"criticalEnabled": True, "highEnabled": True})
    _, apns, _ = poll(state, current=reading(250))
    assert apns.calls[0][1]["critical"] is False  # only the hypoglycemia alerts are critical


def test_stale_alert_fires_even_without_a_new_reading():
    state = State(device_token=TOKEN, live_enabled=True, activity_token=TOKEN, last_sent_ts=NOW)
    _, apns, _ = poll(state, current=reading(120, age_min=20))
    assert apns.names() == ["send_alert"]  # and no duplicate Live Activity push
    assert apns.calls[0][1]["kind"] == "stale"


def test_snooze_from_the_registration_is_honoured():
    state = State(device_token=TOKEN, snooze_until=NOW + 600)
    assert poll(state, current=reading(60))[1].calls == []
