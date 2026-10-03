"""Participant-facing types. No ROS, Docker or third-party Python imports."""

from dataclasses import dataclass
import math


def wrap_angle(angle: float) -> float:
    """Represent an angle in [-pi, pi]; positive means left of the car."""
    return math.atan2(math.sin(angle), math.cos(angle))


@dataclass(frozen=True)
class Observation:
    ranges: tuple[float, ...]  # metres: zero means unknown/invalid; clear rays use range_max
    angle_min: float          # radians, in the LiDAR frame
    angle_increment: float   # radians per ray
    range_max: float
    speed_mps: float          # measured forward speed, not throttle
    x: float                  # simulator world position, metres
    y: float
    yaw: float                # simulator world heading, radians
    dt: float                 # elapsed controller time, seconds

    def sector(self, low: float, high: float) -> tuple[float, ...]:
        """Distances in an angular sector, e.g. sector(-0.2, 0.2) looks forward.

        Bounds are radians in [-pi, pi], with low <= high. Keep zero readings:
        unknown space is not evidence of a clear road.
        """
        return tuple(distance for i, distance in enumerate(self.ranges)
                     if low <= wrap_angle(self.angle_min + i * self.angle_increment) <= high)


@dataclass(frozen=True)
class DriveCommand:
    speed_mps: float = 0.0     # requested forward speed; runtime caps it at 1 m/s
    steering_rad: float = 0.0  # wheel angle; positive turns left; limit is +/-30 degrees
