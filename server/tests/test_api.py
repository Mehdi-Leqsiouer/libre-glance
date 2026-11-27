import hashlib

import pytest
from fakes import FakeStore
from fastapi.testclient import TestClient

from libreglance import api

BODY = {"activity_token": "t" * 20, "min_target": 70, "max_target": 180}
KEY = {"X-Api-Key": api.derive_key("ada@example.com", "pw")}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("LLU_EMAIL", "Ada@Example.com")
    monkeypatch.setenv("LLU_PASSWORD", "pw")
    store = FakeStore()
    api.app.dependency_overrides[api.get_store] = lambda: store
    test_client = TestClient(api.app)
    test_client.store = store
    yield test_client
    api.app.dependency_overrides.clear()


def test_derived_key_ignores_email_case_and_spaces():
    expected = hashlib.sha256(b"libreglance:ada@example.com:pw").hexdigest()
    # same vector as test/push_registration_test.dart: the app and the server must agree
    assert expected == "df4365b6456ca98cc2d147c6f7ab9f73b6bc733af409aa86076091787f3ef5e2"
    assert api.derive_key(" Ada@Example.com ", "pw") == expected


def test_register_with_the_derived_key(client):
    response = client.post("/register", json=BODY, headers=KEY)

    assert response.status_code == 200
    state = client.store.state
    assert state.activity_token == "t" * 20
    assert state.live_enabled is True
    assert state.last_sent_ts == 0
    assert state.activity_started_at > 0


def test_every_endpoint_rejects_a_wrong_or_missing_key(client):
    for path, body in (("/register", BODY), ("/unregister", None), ("/snooze", {"minutes": 5})):
        assert client.post(path, json=body).status_code == 401
        assert client.post(path, json=body, headers={"X-Api-Key": "nope"}).status_code == 401
    assert client.store.state.activity_token is None


def test_tokens_arrive_separately_and_settings_are_stored(client):
    thresholds = {"min_target": 65, "max_target": 170}
    settings = {"staleMinutes": 25, "criticalEnabled": True}
    client.post("/register", json={**thresholds, "device_token": "d" * 20}, headers=KEY)
    client.post(
        "/register",
        json={**thresholds, "push_to_start_token": "p" * 20, "settings": settings},
        headers=KEY,
    )

    state = client.store.state
    assert (state.device_token, state.push_to_start_token) == ("d" * 20, "p" * 20)
    assert state.activity_token is None
    assert state.live_enabled is False
    assert state.settings == settings
    assert (state.min_target, state.max_target) == (65, 170)


def test_the_activity_clock_only_restarts_on_a_new_token(client):
    client.post("/register", json=BODY, headers=KEY)
    started = client.store.state.activity_started_at
    client.store.state.activity_started_at = started - 1000

    client.post("/register", json=BODY, headers=KEY)  # same token, e.g. thresholds changed
    assert client.store.state.activity_started_at == started - 1000

    client.post("/register", json={**BODY, "activity_token": "n" * 20}, headers=KEY)
    assert client.store.state.activity_started_at > started - 1000


def test_unregister_stops_the_live_activity_but_keeps_alerts(client):
    client.post(
        "/register",
        json={**BODY, "device_token": "d" * 20, "push_to_start_token": "p" * 20},
        headers=KEY,
    )

    assert client.post("/unregister", headers=KEY).status_code == 200

    state = client.store.state
    assert (state.activity_token, state.push_to_start_token, state.live_enabled) == (
        None,
        None,
        False,
    )
    assert state.device_token == "d" * 20


def test_snooze_sets_and_clears_the_deadline(client):
    until = client.post("/snooze", json={"minutes": 30}, headers=KEY).json()["snooze_until"]
    assert until > 0
    assert client.store.state.snooze_until == until

    client.post("/snooze", json={"minutes": 0}, headers=KEY)
    assert client.store.state.snooze_until == 0
    assert client.post("/snooze", json={"minutes": 99999}, headers=KEY).status_code == 422
