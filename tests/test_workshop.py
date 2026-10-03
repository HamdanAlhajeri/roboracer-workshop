import math
from types import SimpleNamespace as NS
import unittest

import controller
from examples.follow_the_gap import drive as example
from runtime.bridge import CommandExpiry, REQUIRED_FIELDS, install_startup_guard
from runtime.core import MAX_THROTTLE, clean_scan, fresh_stamp, read_odometry, simulator_command
from workshop_api import DriveCommand, Observation


def observation(ranges=None, speed=0.0):
    return Observation(tuple(ranges or [4.0] * 181), -math.pi / 2, math.pi / 180,
                       10.0, speed, 0.0, 0.0, 0.0, 0.05)


class ParticipantTests(unittest.TestCase):
    def test_participant_controller_returns_a_valid_command(self):
        # Keep this useful after participants replace the stopped starter.
        result = controller.drive(observation())
        self.assertIsInstance(result, DriveCommand)
        self.assertTrue(math.isfinite(result.speed_mps))
        self.assertTrue(math.isfinite(result.steering_rad))

    def test_example_drives_straight_in_symmetric_free_space(self):
        result = example(observation())
        self.assertGreater(result.speed_mps, 0)
        self.assertLessEqual(result.speed_mps, 1)
        self.assertAlmostEqual(result.steering_rad, 0, places=7)

    def test_example_turns_away_from_blocked_right_side(self):
        result = example(observation([0.3] * 60 + [4.0] * 121))
        self.assertGreater(result.steering_rad, 0)

    def test_example_stops_without_a_gap(self):
        self.assertEqual(example(observation([0.2] * 181)), DriveCommand())

    def test_sectors_handle_zero_to_two_pi_scans(self):
        obs = Observation(tuple(range(360)), 0, math.pi / 180, 400, 0, 0, 0, 0, 0.05)
        sector = obs.sector(-0.03, 0.03)
        self.assertEqual(set(sector), {0, 1, 359})

    def test_no_ray_in_forward_sector_is_not_clear_space(self):
        obs = Observation((4.0,) * 32, 1.0, 0.01, 10, 0, 0, 0, 0, 0.05)
        self.assertEqual(simulator_command(DriveCommand(1, 0), obs), (0, 0))


class InputTests(unittest.TestCase):
    def scan(self, ranges):
        return NS(ranges=ranges, angle_min=-math.pi, angle_increment=0.01,
                  range_min=0.05, range_max=10.0)

    def test_clear_no_return_is_valid_but_corrupt_is_unknown(self):
        result = clean_scan(self.scan([math.inf] * 30 + [math.nan, -math.inf]))
        self.assertEqual(result, (10.0,) * 30 + (0.0, 0.0))

    def test_mostly_invalid_scan_is_rejected(self):
        with self.assertRaises(ValueError):
            clean_scan(self.scan([math.nan] * 32))

    def test_invalid_angle_and_range_metadata_rejected(self):
        for key, value in [('angle_min', math.nan), ('angle_increment', 0), ('range_max', 0)]:
            msg = self.scan([1.0] * 32)
            setattr(msg, key, value)
            with self.assertRaises(ValueError):
                clean_scan(msg)

    def test_source_timestamp_freshness(self):
        self.assertTrue(fresh_stamp(99.9, 100))
        for stamp in (0, 1, 101, math.nan):
            self.assertFalse(fresh_stamp(stamp, 100))

    def test_body_speed_is_not_rotated_by_world_heading(self):
        q = NS(x=0, y=0, z=math.sin(math.pi / 4), w=math.cos(math.pi / 4))
        msg = NS(pose=NS(pose=NS(position=NS(x=1, y=2), orientation=q)),
                 twist=NS(twist=NS(linear=NS(x=0.7))))
        self.assertAlmostEqual(read_odometry(msg)[3], 0.7)
        self.assertAlmostEqual(read_odometry(msg)[2], math.pi / 2)
        q.w = 0
        with self.assertRaises(ValueError):
            read_odometry(msg)


class OutputTests(unittest.TestCase):
    def test_speed_steering_and_throttle_are_bounded(self):
        throttle, steering = simulator_command(DriveCommand(100, 10), observation())
        self.assertLessEqual(throttle, MAX_THROTTLE)
        self.assertEqual(steering, 1)
        self.assertEqual(throttle, simulator_command(DriveCommand(1, 10), observation())[0])

    def test_stop_reverse_and_overspeed_remove_throttle(self):
        for command, speed in ((DriveCommand(), 0), (DriveCommand(-1), 0), (DriveCommand(1), 2)):
            self.assertEqual(simulator_command(command, observation(speed=speed))[0], 0)

    def test_front_unknown_or_obstacle_removes_throttle(self):
        for distance in (0, 0.2):
            scan = [4.0] * 181
            scan[90] = distance
            self.assertEqual(simulator_command(DriveCommand(1), observation(scan)), (0, 0))

    def test_invalid_controller_result_is_rejected(self):
        for command in (None, (1, 0), DriveCommand(math.nan), DriveCommand(1, math.inf)):
            with self.assertRaises(ValueError):
                simulator_command(command, observation())


class BridgeTests(unittest.TestCase):
    def test_expiry_is_independent_of_controller_callbacks(self):
        now = [10.0]
        guard = CommandExpiry(clock=lambda: now[0])
        guard.receive('throttle', 0.1)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
        guard.receive('steering', 0.2)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.1')
        now[0] += 0.501
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
        guard.receive('throttle', 0.1)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')

    def test_invalid_command_and_reset_clear_both_axes(self):
        guard = CommandExpiry()
        for invalidate in (lambda: guard.receive('throttle', math.nan), guard.invalidate):
            guard.receive('throttle', 0.1)
            guard.receive('steering', 0.2)
            invalidate()
            self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
            self.assertEqual(guard.gate({})['V1 Steering'], '0.0')

    def test_incomplete_startup_packet_still_gets_stopped_reply(self):
        emitted, forwarded = [], []
        stock = NS(sio=NS(on=lambda event: lambda fn: fn,
                          emit=lambda *a, **kw: emitted.append(kw)),
                   bridge=lambda *args: forwarded.append(args))
        handler = install_startup_guard(stock)
        handler('client', {'V1 Throttle': '1'})
        self.assertEqual(emitted[0]['data']['V1 Throttle'], '0')
        self.assertEqual(forwarded, [])
        frame = dict.fromkeys(REQUIRED_FIELDS, 'value')
        handler('client', frame)
        self.assertEqual(forwarded, [('client', frame)])


if __name__ == '__main__':
    unittest.main()
