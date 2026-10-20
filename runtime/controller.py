from workshop_api import DriveCommand, Observation
 
def drive(observation: Observation) -> DriveCommand:
    # 1. Look at observation.ranges / .sector()
    # 2. Choose a steering angle from free space
    # 3. Choose a speed (slower in corners)
    # 4. Return one command, no loops or sleep
    return DriveCommand(speed_mps=0.0,
                        steering_rad=0.0)
