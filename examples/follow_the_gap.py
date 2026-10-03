"""Small teaching example, not a validated racing controller.

Find a continuous free sector ahead, aim at its middle, and use geometric
Pure Pursuit to convert the target bearing into a wheel angle.
"""

import math

from workshop_api import DriveCommand, Observation, wrap_angle


def drive(observation: Observation) -> DriveCommand:
    rays = sorted(
        (wrap_angle(observation.angle_min + i * observation.angle_increment), min(r, 3.0))
        for i, r in enumerate(observation.ranges)
        if abs(wrap_angle(observation.angle_min + i * observation.angle_increment))
        <= math.radians(80) + 1e-9
    )
    if not rays:
        return DriveCommand()

    # Inflate close obstacles by an approximate half-width plus clearance.
    blocked = [r < 1.2 for _, r in rays]
    for angle, distance in rays:
        if distance < 1.2:
            bubble = math.atan2(0.25, max(distance, 0.01))
            for i, (other_angle, _) in enumerate(rays):
                if abs(other_angle - angle) < bubble:
                    blocked[i] = True

    gaps, current = [], []
    for i, (ray, is_blocked) in enumerate(zip(rays, blocked)):
        if current and ray[0] - rays[current[-1]][0] > 1.5 * observation.angle_increment:
            gaps.append(current)
            current = []
        if is_blocked:
            if current:
                gaps.append(current)
                current = []
        else:
            current.append(i)
    if current:
        gaps.append(current)
    if not gaps:
        return DriveCommand()

    gap = max(gaps, key=len)
    bearing = (rays[gap[0]][0] + rays[gap[-1]][0]) / 2
    # delta = atan(2 * wheelbase * sin(bearing) / lookahead)
    steering = math.atan2(2 * 0.324 * math.sin(bearing), 1.0)
    speed = 0.8 / (1 + 2 * abs(steering))
    return DriveCommand(speed_mps=speed, steering_rad=steering)
