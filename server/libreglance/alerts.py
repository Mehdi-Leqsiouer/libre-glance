"""Alert decisions, ported from lib/services/alert_engine.dart (keep both in sync)."""

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from typing import Any

from .llu import Reading


class Kind(StrEnum):
    # Values are the Dart enum names: they travel in the registration payload.
    URGENT_LOW = "urgentLow"
    LOW = "low"
    FAST_FALL = "fastFall"
    HIGH = "high"
    STALE = "stale"
    SENSOR_EXPIRY = "sensorExpiry"


LABELS = {
    Kind.URGENT_LOW: "Hypoglycémie urgente",
    Kind.LOW: "Hypoglycémie",
    Kind.FAST_FALL: "Chute rapide",
    Kind.HIGH: "Hyperglycémie",
    Kind.STALE: "Perte de données",
    Kind.SENSOR_EXPIRY: "Capteur bientôt expiré",
}

# Minutes before the same alert may fire again while its condition persists.
REPEAT_MINUTES = {
    Kind.URGENT_LOW: 5,
    Kind.LOW: 15,
    Kind.FAST_FALL: 15,
    Kind.HIGH: 60,
    Kind.STALE: 30,
    Kind.SENSOR_EXPIRY: 720,
}

ARROWS = {1: "↓", 2: "↘", 3: "→", 4: "↗", 5: "↑"}


@dataclass(frozen=True)
class Settings:
    """Same keys and defaults as `AlertSettings` in lib/models/alerts.dart."""

    urgent_low_enabled: bool = True
    urgent_low: int = 55
    low_enabled: bool = True
    fast_fall_enabled: bool = True
    high_enabled: bool = False
    stale_enabled: bool = True
    stale_minutes: int = 15
    critical_enabled: bool = False
    sensor_enabled: bool = True
    sensor_days: int = 15
    use_libre_thresholds: bool = False  # take low / high / urgent low from LibreLink instead

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Settings":
        d = cls()
        return cls(
            urgent_low_enabled=bool(data.get("urgentLowEnabled", d.urgent_low_enabled)),
            urgent_low=int(data.get("urgentLow", d.urgent_low)),
            low_enabled=bool(data.get("lowEnabled", d.low_enabled)),
            fast_fall_enabled=bool(data.get("fastFallEnabled", d.fast_fall_enabled)),
            high_enabled=bool(data.get("highEnabled", d.high_enabled)),
            stale_enabled=bool(data.get("staleEnabled", d.stale_enabled)),
            stale_minutes=int(data.get("staleMinutes", d.stale_minutes)),
            critical_enabled=bool(data.get("criticalEnabled", d.critical_enabled)),
            sensor_enabled=bool(data.get("sensorEnabled", d.sensor_enabled)),
            sensor_days=int(data.get("sensorDays", d.sensor_days)),
            use_libre_thresholds=bool(data.get("useLibreThresholds", d.use_libre_thresholds)),
        )


def sensor_time_left(
    sensor_start: datetime | None, settings: Settings, now: datetime
) -> timedelta | None:
    if sensor_start is None:
        return None
    return sensor_start + timedelta(days=settings.sensor_days) - now


def _glucose_conditions(
    reading: Reading, min_target: int, max_target: int, settings: Settings
) -> set[Kind]:
    active: set[Kind] = set()
    if settings.urgent_low_enabled and reading.value < settings.urgent_low:
        active.add(Kind.URGENT_LOW)
    elif settings.low_enabled and reading.value < min_target:
        active.add(Kind.LOW)
    falling_near_low = reading.trend == 1 and min_target <= reading.value <= min_target + 30
    if settings.fast_fall_enabled and falling_near_low:
        active.add(Kind.FAST_FALL)
    if settings.high_enabled and reading.value > max_target:
        active.add(Kind.HIGH)
    return active


def _data_conditions(
    reading: Reading, settings: Settings, now: datetime, sensor_start: datetime | None
) -> set[Kind]:
    active: set[Kind] = set()
    age = now - reading.timestamp
    if settings.stale_enabled and age >= timedelta(minutes=settings.stale_minutes):
        active.add(Kind.STALE)
    left = sensor_time_left(sensor_start, settings, now) if settings.sensor_enabled else None
    if left is not None and timedelta(hours=-12) < left <= timedelta(hours=24):
        active.add(Kind.SENSOR_EXPIRY)
    return active


def evaluate(
    reading: Reading,
    *,
    min_target: int,
    max_target: int,
    settings: Settings,
    last_fired: dict[str, float],
    snooze_until: float | None,
    now: datetime,
    sensor_start: datetime | None = None,
) -> tuple[list[Kind], dict[str, float]]:
    """Alerts to send now and the new `last_fired` map (epoch seconds, by kind).

    An urgent low supersedes the plain low; a condition that clears is forgotten so its
    next occurrence fires at once; snooze mutes everything except the urgent low.
    """
    active = _glucose_conditions(reading, min_target, max_target, settings)
    active |= _data_conditions(reading, settings, now, sensor_start)

    now_s = now.timestamp()
    snoozed = snooze_until is not None and now_s < snooze_until
    fire = [
        kind
        for kind in Kind
        if kind in active
        and (not snoozed or kind is Kind.URGENT_LOW)
        and (
            kind.value not in last_fired
            or now_s - last_fired[kind.value] >= REPEAT_MINUTES[kind] * 60
        )
    ]
    new_last = {k: v for k, v in last_fired.items() if k in {a.value for a in active}}
    new_last.update({kind.value: now_s for kind in fire})
    return fire, new_last


def message(
    kind: Kind,
    reading: Reading,
    patient: str,
    now: datetime,
    sensor_left: timedelta | None = None,
) -> str:
    who = f"{patient} : " if patient else ""
    age_min = max(0, int((now - reading.timestamp).total_seconds() // 60))
    age = "à l'instant" if age_min < 1 else f"il y a {age_min} min"
    if kind is Kind.STALE:
        return (
            f"{who}aucune mesure récente ({age}). Le téléphone de la maison est-il "
            "connecté au capteur ?"
        )
    if kind is Kind.SENSOR_EXPIRY:
        if sensor_left is None or sensor_left < timedelta(0):
            return f"{who}le capteur a atteint sa durée de vie : pense à le remplacer."
        hours = int(sensor_left.total_seconds() // 3600)
        return f"{who}le capteur expire dans {hours} h : prévois un nouveau capteur."
    return f"{who}{reading.value} mg/dL {ARROWS.get(reading.trend, '→')} ({age})"
