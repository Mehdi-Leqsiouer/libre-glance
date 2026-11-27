import hashlib
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta

import httpx

BASE_URL = "https://api-eu.libreview.io"
# Abbott rejects old versions (status 920 with minimumVersion): bump when it does.
VERSION = "4.16.0"


class LibreLinkUpError(Exception):
    pass


class SensorWarmingUp(LibreLinkUpError):
    """A new sensor has no measurement yet: expected, not a failure."""


@dataclass(frozen=True)
class Reading:
    value: int
    trend: int  # 1 = falling fast ... 5 = rising fast
    timestamp: datetime  # UTC


@dataclass(frozen=True)
class LibreAlarms:
    """Alarm thresholds (mg/dL) configured in the patient's LibreLink app."""

    low: int | None
    high: int | None
    urgent_low: int | None


@dataclass(frozen=True)
class Snapshot:
    reading: Reading
    patient: str
    sensor_start: datetime | None
    alarms: LibreAlarms | None


@dataclass(frozen=True)
class Session:
    token: str
    account_id: str
    base_url: str = BASE_URL

    def to_dict(self) -> dict[str, str]:
        return asdict(self)


def parse_timestamp(raw: str) -> datetime:
    """LibreView format "M/d/yyyy h:mm:ss a"; `FactoryTimestamp` is in UTC."""
    return datetime.strptime(raw.strip(), "%m/%d/%Y %I:%M:%S %p").replace(tzinfo=UTC)


def account_id(user_id: str) -> str:
    return hashlib.sha256(user_id.encode()).hexdigest()


def parse_sensor_start(sensor: object) -> datetime | None:
    """`connection.sensor.a` is the activation time in unix seconds."""
    activated = sensor.get("a") if isinstance(sensor, dict) else None
    return datetime.fromtimestamp(activated, UTC) if isinstance(activated, int | float) else None


def in_warmup(sensor: object, sensor_start: datetime | None, now: datetime) -> bool:
    """The sensor reports nothing during its warm-up (`sensor.w` minutes, 60 by default)."""
    if sensor_start is None:
        return False
    minutes = sensor.get("w") if isinstance(sensor, dict) else None
    warmup = minutes if isinstance(minutes, int | float) else 60
    return now < sensor_start + timedelta(minutes=warmup)


def parse_alarms(rules: object) -> LibreAlarms | None:
    """The patient's own LibreLink alarm thresholds: low `l`, high `h`, fixed urgent low `f`."""
    if not isinstance(rules, dict):
        return None

    def threshold(key: str) -> int | None:
        rule = rules.get(key)
        value = rule.get("th") if isinstance(rule, dict) else None
        return round(value) if isinstance(value, int | float) else None

    alarms = LibreAlarms(low=threshold("l"), high=threshold("h"), urgent_low=threshold("f"))
    return alarms if alarms != LibreAlarms(None, None, None) else None


def parse_reading(measurement: dict) -> Reading | None:
    value = measurement.get("Value")
    raw_time = measurement.get("FactoryTimestamp")
    if not isinstance(value, int | float) or not isinstance(raw_time, str):
        return None
    trend = measurement.get("TrendArrow")
    return Reading(
        value=round(value),
        trend=trend if isinstance(trend, int) and 1 <= trend <= 5 else 3,
        timestamp=parse_timestamp(raw_time),
    )


class LibreLinkUpClient:
    def __init__(
        self,
        http: httpx.Client,
        email: str,
        password: str,
        session: Session | None = None,
    ) -> None:
        self._http = http
        self._email = email
        self._password = password
        self.session = session

    def _headers(self) -> dict[str, str]:
        headers = {"product": "llu.ios", "version": VERSION, "Content-Type": "application/json"}
        if self.session:
            headers["Authorization"] = f"Bearer {self.session.token}"
            headers["Account-Id"] = self.session.account_id
        return headers

    def login(self) -> Session:
        base_url = self.session.base_url if self.session else BASE_URL
        self.session = None
        for _ in range(2):  # at most one regional redirect
            response = self._http.post(
                f"{base_url}/llu/auth/login",
                headers=self._headers(),
                json={"email": self._email, "password": self._password},
            )
            response.raise_for_status()
            data = response.json().get("data") or {}
            if data.get("redirect") is True:
                base_url = f"https://api-{data['region']}.libreview.io"
                continue
            ticket, user = data.get("authTicket"), data.get("user")
            if not ticket or not user:
                raise LibreLinkUpError(f"login rejected: {response.text[:200]}")
            self.session = Session(ticket["token"], account_id(user["id"]), base_url)
            return self.session
        raise LibreLinkUpError("too many regional redirects")

    def latest(self, now: datetime | None = None) -> Snapshot:
        """What the first followed connection currently reports."""
        if self.session is None:
            self.login()
        response = self._get_connections()
        if response.status_code in (401, 403):
            self.login()
            response = self._get_connections()
        if response.is_error:
            raise LibreLinkUpError(
                f"connections -> HTTP {response.status_code} {response.text[:200]}"
            )
        connections = response.json().get("data")
        if not isinstance(connections, list) or not connections:
            raise LibreLinkUpError("no followed patient on this account")
        first = connections[0]
        sensor_start = parse_sensor_start(first.get("sensor"))
        reading = parse_reading(first.get("glucoseMeasurement") or {})
        if reading is None:
            if in_warmup(first.get("sensor"), sensor_start, now or datetime.now(UTC)):
                raise SensorWarmingUp("sensor warming up")
            raise LibreLinkUpError("no usable glucose measurement")
        name = f"{first.get('firstName', '')} {first.get('lastName', '')}".strip()
        return Snapshot(reading, name, sensor_start, parse_alarms(first.get("alarmRules")))

    def _get_connections(self) -> httpx.Response:
        assert self.session is not None
        return self._http.get(f"{self.session.base_url}/llu/connections", headers=self._headers())
