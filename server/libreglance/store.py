from dataclasses import dataclass, fields
from typing import Any, Protocol


@dataclass
class State:
    activity_token: str | None = None
    min_target: int = 70
    max_target: int = 180
    patient: str = ""
    last_sent_ts: float = 0.0  # epoch seconds of the last reading pushed
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
        # merge: the API (registration) and the job (polling) write different fields concurrently
        self._doc.set(changes, merge=True)
