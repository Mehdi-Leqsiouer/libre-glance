from fastapi.testclient import TestClient

from libreglance import poll_api
from libreglance.llu import LibreLinkUpError


def test_poll_endpoint_reports_the_outcome(monkeypatch):
    monkeypatch.setattr(poll_api, "_deps", lambda: (None, None, None))
    monkeypatch.setattr(poll_api, "poll_once", lambda *args: "pushed 126")

    response = TestClient(poll_api.app).post("/poll")

    assert response.status_code == 200
    assert response.json() == {"outcome": "pushed 126"}


def test_poll_endpoint_turns_upstream_errors_into_502(monkeypatch):
    def boom(*args):
        raise LibreLinkUpError("login rejected")

    monkeypatch.setattr(poll_api, "_deps", lambda: (None, None, None))
    monkeypatch.setattr(poll_api, "poll_once", boom)

    assert TestClient(poll_api.app).post("/poll").status_code == 502
