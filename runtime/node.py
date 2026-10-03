"""ROS wrapper for the participant's pure Python drive(observation) function."""

import argparse
import importlib
import math
import signal
import time

import rclpy
from rclpy.clock import Clock, ClockType
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rclpy.signals import SignalHandlerOptions
from nav_msgs.msg import Odometry
from sensor_msgs.msg import LaserScan
from std_msgs.msg import Bool, Float32

from workshop_api import Observation
from runtime.core import TIMEOUT, clean_scan, fresh_stamp, read_odometry, simulator_command

PREFIX = "/autodrive/roboracer_1"


class WorkshopNode(Node):
    def __init__(self, drive):
        super().__init__("workshop_controller")
        self.drive = drive
        self.inputs = {}
        self.fault = False
        self.last_message = None
        self.previous_tick = time.monotonic()
        self.throttle = self.create_publisher(Float32, PREFIX + "/throttle_command", 1)
        self.steering = self.create_publisher(Float32, PREFIX + "/steering_command", 1)
        self.create_subscription(LaserScan, PREFIX + "/lidar", self.on_scan,
                                 qos_profile_sensor_data)
        self.create_subscription(Odometry, PREFIX + "/odom", self.on_odom,
                                 qos_profile_sensor_data)
        self.create_subscription(Bool, "/autodrive/reset_command", self.on_reset, 1)
        self.steady_clock = Clock(clock_type=ClockType.STEADY_TIME)
        self.create_timer(0.05, self.tick, clock=self.steady_clock)
        self.get_logger().info("Workshop ready; waiting for simulator sensors.")

    def receive(self, key, msg, value):
        stamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        now = self.get_clock().now().nanoseconds * 1e-9
        previous = self.inputs.get(key)
        if not fresh_stamp(stamp, now):
            self.inputs.pop(key, None)
        elif previous and stamp < previous[1]:
            self.inputs.clear()  # clock/reset discontinuity: require new inputs
        elif not previous or stamp > previous[1]:
            self.inputs[key] = (time.monotonic(), stamp, value)
        # Repeated source stamps must not keep the watchdog alive.

    def on_scan(self, msg):
        try:
            self.receive("scan", msg, (clean_scan(msg), msg.angle_min,
                                       msg.angle_increment, msg.range_max))
        except ValueError:
            self.inputs.pop("scan", None)

    def on_odom(self, msg):
        try:
            value = read_odometry(msg)
            previous = self.inputs.get("odom")
            if previous and math.hypot(value[0] - previous[2][0], value[1] - previous[2][1]) > 1:
                self.inputs.clear()
            self.receive("odom", msg, value)
        except ValueError:
            self.inputs.pop("odom", None)

    def on_reset(self, msg):
        if msg.data:
            self.inputs.clear()
            self.publish(0.0, 0.0)

    def ready(self):
        now, ros_now = time.monotonic(), self.get_clock().now().nanoseconds * 1e-9
        return all(key in self.inputs and 0 <= now - self.inputs[key][0] <= TIMEOUT
                   and fresh_stamp(self.inputs[key][1], ros_now) for key in ("scan", "odom"))

    def publish(self, throttle, steering):
        self.throttle.publish(Float32(data=float(throttle)))
        self.steering.publish(Float32(data=float(steering)))

    def report(self, message):
        if message != self.last_message:
            self.get_logger().info(message)
            self.last_message = message

    def tick(self):
        now = time.monotonic()
        dt, self.previous_tick = now - self.previous_tick, now
        if self.fault or not self.ready() or not 0 < dt <= TIMEOUT:
            self.publish(0.0, 0.0)
            self.report("Stopped: controller fault or missing/stale sensors; inspect logs.")
            return
        if (self.count_publishers(PREFIX + "/throttle_command") > 1
                or self.count_publishers(PREFIX + "/steering_command") > 1):
            self.publish(0.0, 0.0)
            self.report("Stopped: another controller is publishing commands.")
            return
        scan, odom = self.inputs["scan"][2], self.inputs["odom"][2]
        observation = Observation(*scan, speed_mps=odom[3], x=odom[0], y=odom[1],
                                  yaw=odom[2], dt=dt)
        try:
            command = self.drive(observation)
            throttle, steering = simulator_command(command, observation)
            if time.monotonic() - now > 0.1 or not self.ready():
                raise ValueError("drive() took too long or its input expired")
        except Exception as exc:
            self.fault = True
            self.publish(0.0, 0.0)
            self.get_logger().error(f"Controller stopped: {exc}. Fix code and restart.")
            return
        self.publish(throttle, steering)
        self.report("Controller active. Starter returns zero until you implement drive().")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller", default="controller")
    options = parser.parse_args()
    drive = importlib.import_module(options.controller).drive
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = WorkshopNode(drive)
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        while not stopped and rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.1)
    finally:
        if rclpy.ok():
            for _ in range(3):
                node.publish(0.0, 0.0)
                time.sleep(0.05)
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
