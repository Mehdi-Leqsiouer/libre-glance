from datetime import UTC, datetime, timedelta

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fakes import NOW

from libreglance.apns import ApnsClient, ApnsResult
from libreglance.llu import (
    LibreAlarms,
    LibreLinkUpClient,
    LibreLinkUpError,
    SensorWarmingUp,
    account_id,
    parse_alarms,
    parse_reading,
    parse_sensor_start,
    parse_timestamp,
)

MEASUREMENT = {"Value": 126, "TrendArrow": 4, "FactoryTimestamp": "11/23/2026 3:05:09 PM"}


def _p8() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


def test_timestamp_is_utc_and_not_zero_padded():
    assert parse_timestamp("1/2/2026 12:30:00 PM") == datetime(2026, 1, 2, 12, 30, tzinfo=UTC)
    assert parse_timestamp("1/2/2026 12:00:00 AM").hour == 0


def test_account_id_is_sha256_hex():
    assert account_id("abc") == ("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


def test_unusable_measurements_are_skipped():
    assert parse_reading({"TrendArrow": 3}) is None
    assert parse_reading({"Value": 100, "FactoryTimestamp": "1/2/2026 1:00:00 PM"}).trend == 3


def test_sensor_start_is_read_from_unix_seconds():
    assert parse_sensor_start({"a": 1_700_000_000}) == datetime.fromtimestamp(1_700_000_000, UTC)
    assert parse_sensor_start(None) is None
    assert parse_sensor_start({"sn": "x"}) is None


def _llu_transport(requests: list[httpx.Request], connections_status: list[int]):
    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/llu/auth/login":
            if request.url.host == "api-eu.libreview.io":
                return httpx.Response(200, json={"data": {"redirect": True, "region": "fr"}})
            return httpx.Response(
                200, json={"data": {"authTicket": {"token": "tok"}, "user": {"id": "u"}}}
            )
        status = connections_status.pop(0)
        if status != 200:
            return httpx.Response(status)
        return httpx.Response(
            200,
            json={
                "data": [
                    {
                        "firstName": "Ada",
                        "lastName": "L",
                        "glucoseMeasurement": MEASUREMENT,
                        "sensor": {"a": 1_700_000_000},
                        "alarmRules": {"l": {"th": 60}, "h": {"th": 240}, "f": {"th": 55}},
                    }
                ]
            },
        )

    return httpx.MockTransport(handler)


def test_llu_follows_region_redirect_and_relogins_on_403():
    requests: list[httpx.Request] = []
    http = httpx.Client(transport=_llu_transport(requests, [403, 200]))
    client = LibreLinkUpClient(http, "a@b.c", "pw")
    snapshot = client.latest()

    assert (snapshot.reading.value, snapshot.reading.trend, snapshot.patient) == (126, 4, "Ada L")
    assert snapshot.sensor_start == datetime.fromtimestamp(1_700_000_000, UTC)
    assert snapshot.alarms == LibreAlarms(low=60, high=240, urgent_low=55)
    logins = [r for r in requests if r.url.path == "/llu/auth/login"]
    # the region learned at the first login is reused by the re-login (no second redirect)
    assert [r.url.host for r in logins] == [
        "api-eu.libreview.io",
        "api-fr.libreview.io",
        "api-fr.libreview.io",
    ]
    assert requests[-1].headers["Account-Id"] == account_id("u")
    assert requests[-1].headers["version"] == "4.16.0"


def test_alarm_rules_are_read_defensively():
    assert parse_alarms({"l": {"th": 60.4}, "h": {"th": 240}}) == LibreAlarms(60, 240, None)
    assert parse_alarms({"c": True}) is None
    assert parse_alarms(None) is None


def _no_measurement_client(sensor: dict):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/llu/auth/login":
            return httpx.Response(
                200, json={"data": {"authTicket": {"token": "t"}, "user": {"id": "u"}}}
            )
        return httpx.Response(200, json={"data": [{"patientId": "p", "sensor": sensor}]})

    return LibreLinkUpClient(httpx.Client(transport=httpx.MockTransport(handler)), "a", "b")


def test_a_sensor_in_its_warmup_has_no_measurement_and_that_is_expected():
    now = datetime(2026, 11, 27, 12, 0, tzinfo=UTC)
    started = now - timedelta(minutes=20)
    client = _no_measurement_client({"a": started.timestamp(), "w": 60})
    with pytest.raises(SensorWarmingUp):
        client.latest(now)

    after = _no_measurement_client({"a": (now - timedelta(minutes=90)).timestamp(), "w": 60})
    with pytest.raises(LibreLinkUpError, match="no usable") as excinfo:
        after.latest(now)
    assert not isinstance(excinfo.value, SensorWarmingUp)


def test_llu_empty_connections_is_a_readable_error():
    http = httpx.Client(
        transport=httpx.MockTransport(
            lambda r: httpx.Response(
                200,
                json={"data": []}
                if r.url.path == "/llu/connections"
                else {"data": {"authTicket": {"token": "t"}, "user": {"id": "u"}}},
            )
        )
    )
    with pytest.raises(LibreLinkUpError, match="no followed patient"):
        LibreLinkUpClient(http, "a", "b").latest()


def _apns(statuses: dict[str, tuple[int, dict]]):
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        status, body = statuses[request.url.host]
        return httpx.Response(status, json=body)

    client = ApnsClient(
        httpx.Client(transport=httpx.MockTransport(handler)),
        _p8(),
        "KEYID12345",
        "TEAMID1234",
        "com.example.app",
    )
    return client, calls


def _aps(request: httpx.Request) -> dict:
    return httpx.Response(200, content=request.content).json()["aps"]


def test_apns_live_activity_update_shape_and_signed_token():
    client, calls = _apns({"api.push.apple.com": (200, {})})
    result = client.send_live_activity("tok", {"glucose": 100}, stale_in_s=600, now=NOW)

    assert result is ApnsResult.OK
    request = calls[0]
    assert request.url.path == "/3/device/tok"
    assert request.headers["apns-push-type"] == "liveactivity"
    assert request.headers["apns-topic"] == "com.example.app.push-type.liveactivity"
    header = jwt.get_unverified_header(request.headers["authorization"].removeprefix("bearer "))
    assert (header["alg"], header["kid"]) == ("ES256", "KEYID12345")
    aps = _aps(request)
    assert aps["event"] == "update"
    assert aps["content-state"] == {"glucose": 100}
    assert aps["stale-date"] == NOW + 600


def test_apns_start_and_end_live_activity():
    client, calls = _apns({"api.push.apple.com": (200, {})})
    client.start_live_activity("pts", {"glucose": 1}, activity_id="ID-1", stale_in_s=60, now=NOW)
    client.end_live_activity("tok", {"glucose": 1}, now=NOW)

    start, end = (_aps(c) for c in calls)
    assert start["event"] == "start"
    assert start["attributes-type"] == "LiveActivitiesAppAttributes"
    assert start["attributes"] == {"id": "ID-1"}
    assert start["alert"]["body"]
    assert (end["event"], end["dismissal-date"]) == ("end", NOW)


def test_apns_alert_shape_normal_and_critical():
    client, calls = _apns({"api.push.apple.com": (200, {})})
    client.send_alert("dev", title="T", body="B", kind="low", critical=False, now=NOW)
    client.send_alert("dev", title="T", body="B", kind="urgentLow", critical=True, now=NOW)

    normal, critical = calls
    assert normal.headers["apns-push-type"] == "alert"
    assert normal.headers["apns-topic"] == "com.example.app"
    assert normal.headers["apns-collapse-id"] == "low"
    assert _aps(normal)["interruption-level"] == "time-sensitive"
    assert _aps(normal)["category"] == "glucose_alert"
    aps = _aps(critical)
    assert aps["interruption-level"] == "critical"
    assert aps["sound"] == {"critical": 1, "name": "default", "volume": 1.0}


def test_apns_falls_back_to_sandbox_then_reports_invalid_token():
    client, calls = _apns(
        {
            "api.push.apple.com": (400, {"reason": "BadDeviceToken"}),
            "api.sandbox.push.apple.com": (200, {}),
        }
    )
    assert client.send_live_activity("t", {}, stale_in_s=1, now=NOW) is ApnsResult.OK
    assert [c.url.host for c in calls] == ["api.push.apple.com", "api.sandbox.push.apple.com"]

    gone, _ = _apns(
        {
            "api.push.apple.com": (400, {"reason": "BadDeviceToken"}),
            "api.sandbox.push.apple.com": (410, {"reason": "Unregistered"}),
        }
    )
    assert gone.send_live_activity("t", {}, stale_in_s=1, now=NOW) is ApnsResult.INVALID_TOKEN
