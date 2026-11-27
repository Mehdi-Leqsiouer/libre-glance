from datetime import UTC, datetime

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from libreglance.apns import ApnsClient, ApnsResult
from libreglance.llu import (
    LibreLinkUpClient,
    LibreLinkUpError,
    Reading,
    account_id,
    parse_reading,
    parse_timestamp,
)
from libreglance.poll import content_state, poll_once
from libreglance.store import State

NOW = 1_800_000_000
MEASUREMENT = {"Value": 126, "TrendArrow": 4, "FactoryTimestamp": "11/23/2026 3:05:09 PM"}


def _p8() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


class FakeStore:
    def __init__(self, state: State) -> None:
        self.state = state

    def load(self) -> State:
        return self.state

    def save(self, **changes) -> None:
        for key, value in changes.items():
            setattr(self.state, key, value)


def test_timestamp_is_utc_and_not_zero_padded():
    assert parse_timestamp("1/2/2026 12:30:00 PM") == datetime(2026, 1, 2, 12, 30, tzinfo=UTC)
    assert parse_timestamp("1/2/2026 12:00:00 AM").hour == 0


def test_account_id_is_sha256_hex():
    assert account_id("abc") == ("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


def test_unusable_measurements_are_skipped():
    assert parse_reading({"TrendArrow": 3}) is None
    assert parse_reading({"Value": 100, "FactoryTimestamp": "1/2/2026 1:00:00 PM"}).trend == 3


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
                "data": [{"firstName": "Ada", "lastName": "L", "glucoseMeasurement": MEASUREMENT}]
            },
        )

    return httpx.MockTransport(handler)


def test_llu_follows_region_redirect_and_relogins_on_403():
    requests: list[httpx.Request] = []
    http = httpx.Client(transport=_llu_transport(requests, [403, 200]))
    client = LibreLinkUpClient(http, "a@b.c", "pw")
    reading, name = client.latest()

    assert (reading.value, reading.trend, name) == (126, 4, "Ada L")
    logins = [r for r in requests if r.url.path == "/llu/auth/login"]
    # the region learned at the first login is reused by the re-login (no second redirect)
    assert [r.url.host for r in logins] == [
        "api-eu.libreview.io",
        "api-fr.libreview.io",
        "api-fr.libreview.io",
    ]
    assert requests[-1].headers["Account-Id"] == account_id("u")
    assert requests[-1].headers["version"] == "4.16.0"


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


def test_apns_request_shape_and_signed_token():
    client, calls = _apns({"api.push.apple.com": (200, {})})
    result = client.send_live_activity("tok", {"glucose": 100}, stale_in_s=600, now=NOW)

    assert result is ApnsResult.OK
    request = calls[0]
    assert request.url.path == "/3/device/tok"
    assert request.headers["apns-push-type"] == "liveactivity"
    assert request.headers["apns-topic"] == "com.example.app.push-type.liveactivity"
    header = jwt.get_unverified_header(request.headers["authorization"].removeprefix("bearer "))
    assert (header["alg"], header["kid"]) == ("ES256", "KEYID12345")
    aps = httpx.Response(200, content=request.content).json()["aps"]
    assert aps["event"] == "update"
    assert aps["content-state"] == {"glucose": 100}
    assert aps["stale-date"] == NOW + 600


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


def test_content_state_matches_the_swift_keys():
    reading = Reading(126, 4, datetime(2026, 11, 23, 15, 5, 9, tzinfo=UTC))
    state = State(min_target=70, max_target=180, patient="Ada")
    assert content_state(reading, state, "") == {
        "glucose": 126,
        "trend": 4,
        "timestampMs": 1_795_446_309_000,
        "minTarget": 70,
        "maxTarget": 180,
        "patient": "Ada",
    }


class FakeLlu:
    session = None

    def __init__(self, reading: Reading) -> None:
        self.reading = reading

    def latest(self):
        return self.reading, "Ada"


class FakeApns:
    def __init__(self, result: ApnsResult) -> None:
        self.result = result
        self.sent: list[dict] = []

    def send_live_activity(self, token, content, *, stale_in_s, now):
        self.sent.append(content)
        return self.result


def test_poll_flow():
    reading = Reading(126, 3, datetime.fromtimestamp(NOW, UTC))

    store = FakeStore(State())
    assert poll_once(FakeLlu(reading), FakeApns(ApnsResult.OK), store, NOW).startswith("no reg")

    store = FakeStore(State(activity_token="t" * 20))
    apns = FakeApns(ApnsResult.OK)
    assert poll_once(FakeLlu(reading), apns, store, NOW) == "pushed 126"
    assert store.state.last_sent_ts == NOW
    assert poll_once(FakeLlu(reading), apns, store, NOW) == "no new reading"
    assert len(apns.sent) == 1

    store = FakeStore(State(activity_token="t" * 20))
    poll_once(FakeLlu(reading), FakeApns(ApnsResult.INVALID_TOKEN), store, NOW)
    assert store.state.activity_token is None

    store = FakeStore(State(activity_token="t" * 20))
    assert "retry" in poll_once(FakeLlu(reading), FakeApns(ApnsResult.FAILED), store, NOW)
    assert store.state.last_sent_ts == 0
