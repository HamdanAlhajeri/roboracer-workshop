r"""YOUR WORKSHOP CODE: edit drive(), save, then run .\workshop.ps1 restart.

The simulator connection, sensor conversion and throttle control are supplied.
This starter deliberately stays stopped. See examples/follow_the_gap.py for
one possible approach, or implement wall following / your own algorithm here.
"""

from workshop_api import DriveCommand, Observation


def drive(observation: Observation) -> DriveCommand:
    """Called at a target rate of 20 Hz while valid sensor data is available.

    1. Inspect observation.ranges or observation.sector(low, high).
    2. Choose a steering angle from the free space ahead.
    3. Choose a speed, reducing it for corners and nearby obstacles.
    4. Return DriveCommand(speed_mps=..., steering_rad=...).

    All distances are metres and all angles are radians. Do not put an infinite
    loop or sleep here: return one command for each observation.
    """
    # TODO: implement your driving algorithm here.
    return DriveCommand()
