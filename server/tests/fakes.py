from datetime import UTC, datetime

from libreglance.apns import ApnsResult
from libreglance.llu import LibreAlarms, Reading, SensorWarmingUp, Snapshot
from libreglance.store import State

NOW = 1_800_000_000


def reading(value: int = 126, trend: int = 3, age_min: int = 0, now: int = NOW) -> Reading:
    return Reading(value, trend, datetime.fromtimestamp(now - age_min * 60, UTC))


class FakeStore:
    def __init__(self, state: State | None = None) -> None:
        self.state = state or State()

    def load(self) -> State:
        return self.state

    def save(self, **changes) -> None:
        for key, value in changes.items():
            setattr(self.state, key, value)


class FakeLlu:
    session = None

    def __init__(
        self,
        current: Reading | None,
        sensor_start: datetime | None = None,
        alarms: LibreAlarms | None = None,
    ) -> None:
        self.current = current
        self.sensor_start = sensor_start
        self.alarms = alarms

    def latest(self, now=None):
        if self.current is None:
            raise SensorWarmingUp("sensor warming up")
        return Snapshot(self.current, "Ada", self.sensor_start, self.alarms)


class FakeApns:
    """Records every call; `results` maps a method name to the result it returns."""

    def __init__(self, **results: ApnsResult) -> None:
        self.results = results
        self.calls: list[tuple[str, dict]] = []

    def _record(self, name: str, **info) -> ApnsResult:
        self.calls.append((name, info))
        return self.results.get(name, ApnsResult.OK)

    def send_live_activity(self, token, content, *, stale_in_s, now):
        return self._record("send_live_activity", token=token, content=content)

    def start_live_activity(self, token, content, *, activity_id, stale_in_s, now):
        return self._record("start_live_activity", token=token, activity_id=activity_id)

    def end_live_activity(self, token, content, *, now):
        return self._record("end_live_activity", token=token)

    def send_alert(self, token, *, title, body, kind, critical, now):
        return self._record("send_alert", kind=kind, title=title, body=body, critical=critical)

    def names(self) -> list[str]:
        return [name for name, _ in self.calls]
