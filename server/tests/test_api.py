import hashlib

import pytest
from fastapi.testclient import TestClient

from libreglance import api
from libreglance.store import State

BODY = {"activity_token": "t" * 20, "min_target": 70, "max_target": 180}


class FakeStore:
    def __init__(self) -> None:
        self.state = State()

    def load(self) -> State:
        return self.state

    def save(self, **changes) -> None:
        for key, value in changes.items():
            setattr(self.state, key, value)


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
    key = api.derive_key("ada@example.com", "pw")

    response = client.post("/register", json=BODY, headers={"X-Api-Key": key})

    assert response.status_code == 200
    assert client.store.state.activity_token == "t" * 20
    assert client.store.state.last_sent_ts == 0


def test_register_rejects_a_wrong_or_missing_key(client):
    assert client.post("/register", json=BODY).status_code == 401
    assert client.post("/register", json=BODY, headers={"X-Api-Key": "nope"}).status_code == 401
    assert client.store.state.activity_token is None
