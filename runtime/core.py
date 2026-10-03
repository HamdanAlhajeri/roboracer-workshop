"""Input validation and simulator command conversion, independent of ROS."""

import math

from workshop_api import DriveCommand

MAX_SPEED = 1.0
MAX_STEERING = math.radians(30)
MAX_THROTTLE = 0.08
TIMEOUT = 0.5


def fresh_stamp(stamp, now):
    return math.isfinite(stamp) and stamp > 0 and -0.1 <= now - stamp <= TIMEOUT


def clean_scan(msg):
    if (len(msg.ranges) < 32
            or not all(math.isfinite(v) for v in
                       (msg.angle_min, msg.angle_increment, msg.range_min, msg.range_max))
            or msg.angle_increment <= 0 or not 0 <= msg.range_min < msg.range_max):
        raise ValueError("invalid LiDAR metadata")
    valid = [r == math.inf or (math.isfinite(r) and msg.range_min <= r <= msg.range_max)
             for r in msg.ranges]
    if sum(valid) < len(valid) / 2:
        raise ValueError("too few valid LiDAR rays")
    return tuple(min(r, msg.range_max) if ok else 0.0 for r, ok in zip(msg.ranges, valid))


def read_odometry(msg):
    p, q, v = msg.pose.pose.position, msg.pose.pose.orientation, msg.twist.twist.linear
    if not all(math.isfinite(n) for n in (p.x, p.y, q.x, q.y, q.z, q.w, v.x)):
        raise ValueError("nonfinite odometry")
    norm = math.sqrt(q.x ** 2 + q.y ** 2 + q.z ** 2 + q.w ** 2)
    if not 0.9 < norm < 1.1:
        raise ValueError("invalid orientation")
    x, y, z, w = q.x / norm, q.y / norm, q.z / norm, q.w / norm
    yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
    # AutoDRIVE publishes body-frame forward velocity here.
    return p.x, p.y, yaw, v.x


def simulator_command(command, observation):
    if not isinstance(command, DriveCommand):
        raise ValueError("drive() must return a DriveCommand")
    if not all(math.isfinite(v) for v in (command.speed_mps, command.steering_rad)):
        raise ValueError("drive() returned a nonfinite value")
    target = min(MAX_SPEED, max(0.0, command.speed_mps))
    steering = min(1.0, max(-1.0, command.steering_rad / MAX_STEERING))
    # A small protective front sector; this is not complete collision avoidance.
    front = observation.sector(-math.radians(12), math.radians(12))
    if not front or min(front) < 0.35:
        return 0.0, 0.0
    if target == 0 or observation.speed_mps > target + 0.05:
        return 0.0, steering
    # Feedforward + proportional speed feedback, calibrated only for this simulator.
    throttle = 0.04 * target + 0.02 * (target - observation.speed_mps)
    return min(MAX_THROTTLE, max(0.0, throttle)), steering
