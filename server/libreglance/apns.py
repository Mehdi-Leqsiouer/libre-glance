import logging
from enum import StrEnum

import httpx
import jwt

log = logging.getLogger(__name__)

# TestFlight / App Store builds use production, Xcode builds use the sandbox.
HOSTS = ("https://api.push.apple.com", "https://api.sandbox.push.apple.com")
# Apple wants the provider token refreshed between every 20 and 60 minutes.
JWT_TTL_S = 45 * 60


class ApnsResult(StrEnum):
    OK = "ok"
    INVALID_TOKEN = "invalid_token"
    FAILED = "failed"


class ApnsClient:
    def __init__(
        self,
        http: httpx.Client,
        key_pem: str,
        key_id: str,
        team_id: str,
        bundle_id: str,
    ) -> None:
        self._http = http
        self._key_pem = key_pem
        self._key_id = key_id
        self._team_id = team_id
        self._topic = f"{bundle_id}.push-type.liveactivity"
        self._jwt: tuple[str, int] | None = None

    def _provider_token(self, now: int) -> str:
        if self._jwt is None or now - self._jwt[1] > JWT_TTL_S:
            token = jwt.encode(
                {"iss": self._team_id, "iat": now},
                self._key_pem,
                algorithm="ES256",
                headers={"kid": self._key_id},
            )
            self._jwt = (token, now)
        return self._jwt[0]

    def send_live_activity(
        self, token: str, content_state: dict, *, stale_in_s: int, now: int
    ) -> ApnsResult:
        body = {
            "aps": {
                "timestamp": now,
                "event": "update",
                "content-state": content_state,
                "stale-date": now + stale_in_s,
            }
        }
        headers = {
            "authorization": f"bearer {self._provider_token(now)}",
            "apns-push-type": "liveactivity",
            "apns-topic": self._topic,
            "apns-priority": "10",
        }
        for host in HOSTS:
            response = self._http.post(f"{host}/3/device/{token}", headers=headers, json=body)
            if response.status_code == 200:
                return ApnsResult.OK
            reason = response.json().get("reason", "") if response.content else ""
            if reason == "BadDeviceToken" and host == HOSTS[0]:
                continue  # probably a sandbox token
            if response.status_code == 410 or reason in ("BadDeviceToken", "Unregistered"):
                return ApnsResult.INVALID_TOKEN
            log.error("APNs %s -> HTTP %s %s", host, response.status_code, reason)
            if reason in ("ExpiredProviderToken", "InvalidProviderToken"):
                self._jwt = None
            return ApnsResult.FAILED
        return ApnsResult.INVALID_TOKEN
