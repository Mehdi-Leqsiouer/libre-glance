"""Mirrors test/alert_engine_test.dart: the app and the server must decide the same way."""

from datetime import UTC, datetime, timedelta

from fakes import NOW, reading

from libreglance.alerts import Kind, Settings, evaluate, message

WHEN = datetime.fromtimestamp(NOW, UTC)


def fire(r, settings=None, last=None, snooze=None, now=WHEN, sensor_start=None, lo=70, hi=180):
    return evaluate(
        r,
        min_target=lo,
        max_target=hi,
        settings=settings or Settings(),
        last_fired=last or {},
        snooze_until=snooze,
        now=now,
        sensor_start=sensor_start,
    )


def kinds(*args, **kwargs):
    return fire(*args, **kwargs)[0]


def test_in_range_fires_nothing():
    assert kinds(reading(120)) == []


def test_low_fires_and_urgent_low_supersedes_it():
    assert kinds(reading(65)) == [Kind.LOW]
    assert kinds(reading(50)) == [Kind.URGENT_LOW]


def test_urgent_low_disabled_leaves_a_plain_low():
    assert kinds(reading(50), Settings(urgent_low_enabled=False)) == [Kind.LOW]


def test_every_alert_can_be_disabled():
    assert kinds(reading(65), Settings(low_enabled=False)) == []
    assert kinds(reading(200)) == []  # high is off by default
    assert kinds(reading(200), Settings(high_enabled=True)) == [Kind.HIGH]
    assert kinds(reading(120, age_min=30), Settings(stale_enabled=False)) == []


def test_thresholds_come_from_the_registration():
    assert kinds(reading(80), lo=90) == [Kind.LOW]
    assert kinds(reading(190), Settings(high_enabled=True), hi=200) == []


def test_stale_data_uses_the_configured_delay():
    assert kinds(reading(120, age_min=14)) == []
    assert kinds(reading(120, age_min=15)) == [Kind.STALE]
    assert kinds(reading(120, age_min=20), Settings(stale_minutes=25)) == []


def test_fast_fall_only_near_the_low_threshold():
    assert kinds(reading(95, trend=1)) == [Kind.FAST_FALL]
    assert kinds(reading(150, trend=1)) == []


def test_repeats_after_the_cooldown_and_resets_when_back_in_range():
    _, last = fire(reading(65))
    later = WHEN + timedelta(minutes=10)
    assert kinds(reading(65, now=NOW + 600), last=last, now=later) == []
    later = WHEN + timedelta(minutes=15)
    assert kinds(reading(65, now=NOW + 900), last=last, now=later) == [Kind.LOW]

    _, cleared = fire(reading(120, now=NOW + 300), last=last, now=WHEN + timedelta(minutes=5))
    assert cleared == {}


def test_snooze_mutes_everything_except_urgent_low():
    snooze = NOW + 1800
    assert kinds(reading(65), snooze=snooze) == []
    assert kinds(reading(50), snooze=snooze) == [Kind.URGENT_LOW]
    later = WHEN + timedelta(minutes=31)
    assert kinds(reading(65, now=NOW + 1860), snooze=snooze, now=later) == [Kind.LOW]


def test_sensor_expiry_in_the_last_24_hours_only():
    start = WHEN - timedelta(days=12)
    assert kinds(reading(120), sensor_start=start) == []
    assert kinds(reading(120), sensor_start=WHEN - timedelta(days=13, hours=1)) == [
        Kind.SENSOR_EXPIRY
    ]
    assert kinds(reading(120), sensor_start=WHEN - timedelta(days=14, hours=13)) == []
    assert (
        kinds(reading(120), Settings(sensor_enabled=False), sensor_start=WHEN - timedelta(days=14))
        == []
    )
    assert (
        kinds(
            reading(120), Settings(sensor_days=15), sensor_start=WHEN - timedelta(days=13, hours=1)
        )
        == []
    )


def test_settings_use_the_dart_json_keys_and_defaults():
    parsed = Settings.from_dict({"staleMinutes": 25, "highEnabled": True, "criticalEnabled": True})
    assert (parsed.stale_minutes, parsed.high_enabled, parsed.critical_enabled) == (25, True, True)
    assert Settings.from_dict({}) == Settings()


def test_messages_are_the_ones_of_the_app():
    text = message(Kind.LOW, reading(65, trend=2, age_min=3), "Ada", WHEN)
    assert text == "Ada : 65 mg/dL ↘ (il y a 3 min)"
    assert "aucune mesure récente" in message(Kind.STALE, reading(120, age_min=20), "", WHEN)
    assert "expire dans 5 h" in message(
        Kind.SENSOR_EXPIRY, reading(120), "", WHEN, timedelta(hours=5, minutes=10)
    )
