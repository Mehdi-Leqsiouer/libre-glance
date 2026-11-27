import logging
from enum import StrEnum
from typing import Any

import httpx
import jwt

log = logging.getLogger(__name__)

# TestFlight / App Store builds use production, Xcode builds use the sandbox.
HOSTS = ("https://api.push.apple.com", "https://api.sandbox.push.apple.com")
# Apple wants the provider token refreshed between every 20 and 60 minutes.
JWT_TTL_S = 45 * 60
# Must match the Swift attributes type of the Live Activity extension.
ATTRIBUTES_TYPE = "LiveActivitiesAppAttributes"


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
        self._bundle_id = bundle_id
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

    def _send(
        self,
        token: str,
        *,
        push_type: str,
        topic: str,
        body: dict[str, Any],
        now: int,
        collapse_id: str | None = None,
    ) -> ApnsResult:
        headers = {
            "authorization": f"bearer {self._provider_token(now)}",
            "apns-push-type": push_type,
            "apns-topic": topic,
            "apns-priority": "10",
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id
        for host in HOSTS:
            response = self._http.post(f"{host}/3/device/{token}", headers=headers, json=body)
            if response.status_code == 200:
                return ApnsResult.OK
            reason = response.json().get("reason", "") if response.content else ""
            if reason == "BadDeviceToken" and host == HOSTS[0]:
                continue  # probably a sandbox token
            if response.status_code == 410 or reason in ("BadDeviceToken", "Unregistered"):
                return ApnsResult.INVALID_TOKEN
            log.error("APNs %s %s -> HTTP %s %s", push_type, host, response.status_code, reason)
            if reason in ("ExpiredProviderToken", "InvalidProviderToken"):
                self._jwt = None
            return ApnsResult.FAILED
        return ApnsResult.INVALID_TOKEN

    @property
    def _live_activity_topic(self) -> str:
        return f"{self._bundle_id}.push-type.liveactivity"

    def send_live_activity(
        self, token: str, content_state: dict, *, stale_in_s: int, now: int
    ) -> ApnsResult:
        aps = {
            "timestamp": now,
            "event": "update",
            "content-state": content_state,
            "stale-date": now + stale_in_s,
        }
        return self._send(
            token,
            push_type="liveactivity",
            topic=self._live_activity_topic,
            body={"aps": aps},
            now=now,
        )

    def start_live_activity(
        self,
        push_to_start_token: str,
        content_state: dict,
        *,
        activity_id: str,
        stale_in_s: int,
        now: int,
    ) -> ApnsResult:
        """Starts a new Live Activity remotely (iOS 17.2+), e.g. after the 8 h limit."""
        aps = {
            "timestamp": now,
            "event": "start",
            "content-state": content_state,
            "attributes-type": ATTRIBUTES_TYPE,
            "attributes": {"id": activity_id},
            "stale-date": now + stale_in_s,
            "alert": {"title": "LibreGlance", "body": "Live Activity relancée"},
        }
        return self._send(
            push_to_start_token,
            push_type="liveactivity",
            topic=self._live_activity_topic,
            body={"aps": aps},
            now=now,
        )

    def end_live_activity(self, token: str, content_state: dict, *, now: int) -> ApnsResult:
        aps = {
            "timestamp": now,
            "event": "end",
            "content-state": content_state,
            "dismissal-date": now,
        }
        return self._send(
            token,
            push_type="liveactivity",
            topic=self._live_activity_topic,
            body={"aps": aps},
            now=now,
        )

    def send_alert(
        self,
        device_token: str,
        *,
        title: str,
        body: str,
        kind: str,
        critical: bool,
        now: int,
    ) -> ApnsResult:
        """A visible notification. `category` brings back the snooze actions of the app."""
        aps: dict[str, Any] = {
            "alert": {"title": title, "body": body},
            "category": "glucose_alert",
            "thread-id": kind,
            "interruption-level": "critical" if critical else "time-sensitive",
            "sound": {"critical": 1, "name": "default", "volume": 1.0} if critical else "default",
        }
        return self._send(
            device_token,
            push_type="alert",
            topic=self._bundle_id,
            body={"aps": aps},
            now=now,
            collapse_id=kind,
        )
