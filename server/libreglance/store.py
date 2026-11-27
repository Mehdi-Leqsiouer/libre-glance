from dataclasses import dataclass, field, fields
from typing import Any, Protocol


@dataclass
class State:
    # Live Activity
    activity_token: str | None = None
    push_to_start_token: str | None = None
    live_enabled: bool = False  # the user turned the Dynamic Island switch on
    auto_restart: bool = True
    activity_started_at: float = 0.0  # when the current activity token was first registered
    last_start_at: float = 0.0  # last push-to-start, to avoid restart loops
    last_sent_ts: float = 0.0  # epoch seconds of the last reading pushed
    # Alerts
    device_token: str | None = None
    settings: dict[str, Any] = field(default_factory=dict)  # AlertSettings.toJson()
    last_fired: dict[str, float] = field(default_factory=dict)
    snooze_until: float = 0.0
    # Shared
    min_target: int = 70
    max_target: int = 180
    patient: str = ""
    llu_session: dict[str, str] | None = None


class Store(Protocol):
    def load(self) -> State: ...

    def save(self, **changes: Any) -> None:
        """Merge the given fields into the stored state."""


class FirestoreStore:
    def __init__(self, client: Any, document: str = "libreglance/state") -> None:
        self._doc = client.document(document)

    def load(self) -> State:
        data = self._doc.get().to_dict() or {}
        known = {f.name for f in fields(State)}
        return State(**{k: v for k, v in data.items() if k in known})

    def save(self, **changes: Any) -> None:
        # Field-level merge: the API (registration) and the poller write different fields
        # concurrently, and a map field (last_fired, settings) must be replaced, not merged.
        self._doc.set(changes, merge=list(changes))
