"""Run inside the ROS image on an isolated ROS domain, without a simulator.

python3 tests/ros_smoke.py (PYTHONPATH must include the workshop directory).
"""

import math
import time

import rclpy
from rclpy.executors import SingleThreadedExecutor
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from nav_msgs.msg import Odometry
from sensor_msgs.msg import LaserScan
from std_msgs.msg import Float32

from runtime.node import PREFIX, WorkshopNode
from workshop_api import DriveCommand


rclpy.init()
worker = WorkshopNode(lambda obs: DriveCommand(0.5, 0.1))
fixture = Node('workshop_smoke_fixture')
scan_pub = fixture.create_publisher(LaserScan, PREFIX + '/lidar', qos_profile_sensor_data)
odom_pub = fixture.create_publisher(Odometry, PREFIX + '/odom', qos_profile_sensor_data)
received = []
fixture.create_subscription(Float32, PREFIX + '/throttle_command',
                            lambda msg: received.append(float(msg.data)), 10)
executor = SingleThreadedExecutor()
executor.add_node(worker)
executor.add_node(fixture)


def pump(seconds, sensors=False, stale=False):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if sensors:
            stamp = fixture.get_clock().now().to_msg()
            if stale:
                stamp.sec -= 10
            scan = LaserScan()
            scan.header.stamp = stamp
            scan.angle_min, scan.angle_increment = -math.pi / 2, math.pi / 180
            scan.range_min, scan.range_max = 0.05, 10.0
            scan.ranges = [4.0] * 181
            odom = Odometry()
            odom.header.stamp = stamp
            odom.pose.pose.orientation.w = 1.0
            scan_pub.publish(scan)
            odom_pub.publish(odom)
        executor.spin_once(timeout_sec=0.01)
        time.sleep(0.005)


try:
    pump(0.8)
    assert received and all(value == 0 for value in received), 'startup moved without sensors'
    received.clear()
    pump(1.0, sensors=True)
    assert any(value > 0 for value in received), 'fresh sensors did not permit driving'
    pump(0.7)
    received.clear()
    pump(0.2)
    assert received and all(value == 0 for value in received), 'sensor loss held throttle'
    received.clear()
    pump(0.3, sensors=True, stale=True)
    assert received and all(value == 0 for value in received), 'old source stamps accepted'
    pump(0.3, sensors=True)
    assert any(value > 0 for value in received), 'fresh sensors failed to recover'
    worker.drive = lambda obs: DriveCommand(float('nan'))
    pump(0.2, sensors=True)
    received.clear()
    pump(0.2, sensors=True)
    assert worker.fault and received and all(value == 0 for value in received)
    print('PASS: real ROS startup, sensor transport, expiry, old timestamps and controller fault')
finally:
    executor.shutdown()
    worker.destroy_node()
    fixture.destroy_node()
    rclpy.shutdown()
