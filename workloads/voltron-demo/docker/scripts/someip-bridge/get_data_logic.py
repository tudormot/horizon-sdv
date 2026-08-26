# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Helper logic and data conversion functions for CARLA vehicle metrics."""

# pylint: disable=import-error, broad-exception-caught, global-statement, invalid-name

import math
import time

import carla


_total_distance_m = 0.0
_last_timestamp = None


def get_vehicle_speed_miles_h(vehicle):
    """Calculates magnitude of velocity vector in miles/h."""
    if not vehicle or not vehicle.is_alive:
        return 0.0
    v = vehicle.get_velocity()
    ms_to_miles_h_conversion = 2.23694
    return ms_to_miles_h_conversion * math.sqrt(v.x**2 + v.y**2 + v.z**2)


def get_vehicle_rpm(vehicle):
    """Calculates vehicle RPM based on speed and gear ratio."""
    if not vehicle or not vehicle.is_alive:
        return 0
    try:
        # 1. Get vehicle velocity (vector) and convert to m/s
        v = vehicle.get_velocity()
        speed_m_s = math.sqrt(v.x**2 + v.y**2 + v.z**2)

        # 2. Get current gear
        control = vehicle.get_control()
        gear = control.gear

        # 3. Determine gear ratio
        # Gear ratios mapping
        gear_ratios = {
            -1: 3.60,  # Reverse
            0: 0.0,  # Neutral (handled by idle RPM logic)
            1: 3.60,
            2: 2.00,
            3: 1.35,
            4: 1.00,
            5: 0.80,
            6: 0.65,
        }

        # Use 0.65 for any gear above 6
        ratio = gear_ratios.get(gear, 0.65 if gear > 6 else 0.0)

        # 4. Calculate RPM
        # rpm_constant is derived from:
        # approx 3.6(final drive) * 60 / (2 * pi * 0.316(tire rolling radius))
        # numbers approximated from 2020 toyota corolla specs
        rpm_constant = 108
        calculated_rpm = speed_m_s * ratio * rpm_constant

        # 5. Handle Idle and Neutral (Minimum 800 RPM)
        if gear == 0 or calculated_rpm < 800:
            return 800

        return int(calculated_rpm)
    except Exception as e:
        print(f"Error calculating RPM: {e}")
        return 800  # Default to idle on error


def get_gnss_data(world, vehicle):
    """Retrieves GNSS data from the vehicle's location, speed and bearing."""
    if not vehicle or not vehicle.is_alive or not world:
        return 0.0, 0.0, 0.0, 0.0, 0.0

    location = vehicle.get_location()
    geo_location = world.get_map().transform_to_geolocation(location)

    v = vehicle.get_velocity()
    speed_m_s = math.sqrt(v.x**2 + v.y**2 + v.z**2)

    transform = vehicle.get_transform()
    yaw = transform.rotation.yaw
    # CARLA: 0 is +X (East), 90 is +Y (South).
    # North is -90 (or 270).
    # Bearing: North=0, East=90, South=180, West=270.
    bearing = (yaw + 90.0) % 360.0

    return (
        geo_location.latitude,
        geo_location.longitude,
        geo_location.altitude,
        speed_m_s,
        bearing,
    )


def get_vehicle_dynamics(vehicle):
    """Retrieves vehicle dynamics: steering, accelerator, and brake."""
    if not vehicle or not vehicle.is_alive:
        return 0.0, 0.0, 0.0

    control = vehicle.get_control()

    # Steering: steer is -1.0 to 1.0. We scale it by max steer angle.
    # We can fetch max steer from physics control.
    physics = vehicle.get_physics_control()
    max_steer = 70.0  # Default fallback
    if physics.wheels:
        max_steer = physics.wheels[0].max_steer_angle

    steering_angle_deg = control.steer * max_steer
    accelerator_pedal_pct = control.throttle * 100.0
    brake_pedal_pct = control.brake * 100.0

    return steering_angle_deg, accelerator_pedal_pct, brake_pedal_pct


def get_odometer_data(vehicle):
    """Integrates velocity to update odometer data (meters)."""
    global _total_distance_m, _last_timestamp

    current_time = time.time()
    if _last_timestamp is None:
        _last_timestamp = current_time
        return int(_total_distance_m)

    dt = current_time - _last_timestamp
    _last_timestamp = current_time

    if not vehicle or not vehicle.is_alive:
        return int(_total_distance_m)

    v = vehicle.get_velocity()
    speed_m_s = math.sqrt(v.x**2 + v.y**2 + v.z**2)

    _total_distance_m += speed_m_s * dt

    return int(_total_distance_m)


def get_ambient_light_data(world):
    """Checks if it's day or night in CARLA world."""
    if not world:
        return False  # Default to DAY

    weather = world.get_weather()
    # 90 is midday, -90 is midnight. 0 is sunset/sunrise.
    # Return True for NIGHT, False for DAY.
    return weather.sun_altitude_angle <= 0


def get_fog_data(world):
    """Checks if there is fog in the CARLA world."""
    if not world:
        return False

    weather = world.get_weather()
    return weather.fog_density > 50.0


def get_vehicle_light_data(vehicle):
    """Retrieves vehicle light states: Fog, Position (Park), HighBeam, LowBeam,

    LeftBlinker, and RightBlinker.
    """
    if not vehicle or not vehicle.is_alive:
        return False, False, False, False, False, False

    light_state = vehicle.get_light_state()

    fog_lights = bool(light_state & carla.VehicleLightState.Fog)
    park_lights = bool(light_state & carla.VehicleLightState.Position)
    hibeam = bool(light_state & carla.VehicleLightState.HighBeam)
    lowbeam = bool(light_state & carla.VehicleLightState.LowBeam)
    turn_signal_left = bool(light_state & carla.VehicleLightState.LeftBlinker)
    turn_signal_right = bool(light_state & carla.VehicleLightState.RightBlinker)

    return (
        fog_lights,
        park_lights,
        hibeam,
        lowbeam,
        turn_signal_left,
        turn_signal_right,
    )


def get_speed_limit_data(vehicle):
    """Retrieves current speed limit in miles/h."""
    if not vehicle or not vehicle.is_alive:
        return 0.0

    speed_limit_kmh = vehicle.get_speed_limit()
    kmh_to_mph = 0.621371
    return float(speed_limit_kmh * kmh_to_mph)


# pylint: disable=too-many-return-statements
def get_automatic_gear_data(vehicle):
    """Maps manual gear to automatic gear enum: P=0, R=1, N=2, D=3."""
    if not vehicle or not vehicle.is_alive:
        return 2  # Default to Neutral

    control = vehicle.get_control()
    gear = control.gear

    # Mapping logic:
    # -1 (Reverse) -> 1 (R)
    # 0 (Neutral) -> 2 (N) (or 0 (P) if handbrake is on)
    # > 0 (Forward) -> 3 (D)

    if gear == -1:
        return 1  # R
    if gear == 0:
        if control.hand_brake:
            return 0  # P
        return 2  # N

    # speed < 0.1 km/h and throttle is 0 -> Neutral (N)
    v = vehicle.get_velocity()
    speed_kmh = 3.6 * math.sqrt(v.x**2 + v.y**2 + v.z**2)
    if speed_kmh < 0.1 and control.throttle == 0.0:
        return 2  # N
    if gear > 0:
        return 3  # D

    return 2  # Default to N


def get_vehicle_acceleration(vehicle):
    """Calculates magnitude of acceleration vector in m/s^2."""
    if not vehicle or not vehicle.is_alive:
        return 0.0
    acc = vehicle.get_acceleration()
    return math.sqrt(acc.x**2 + acc.y**2 + acc.z**2)


def get_handbrake_data(vehicle):
    """Checks if the handbrake is engaged."""
    if not vehicle or not vehicle.is_alive:
        return False
    control = vehicle.get_control()
    return bool(control.hand_brake)


def get_max_speed_data(vehicle):
    """Calculates theoretical maximum speed in miles/h."""
    if not vehicle or not vehicle.is_alive:
        return 0.0
    try:
        physics = vehicle.get_physics_control()

        # Max Speed = (Max RPM / 60) * (1 / (Final Ratio * Min Gear Ratio)) * (Wheel Circumference)
        max_rpm = physics.max_rpm
        final_ratio = physics.final_ratio

        # Get minimum forward gear ratio (highest gear)
        if not physics.forward_gears:
            return 0.0
        min_gear_ratio = min(
            gear.ratio for gear in physics.forward_gears if gear.ratio > 0
        )

        # Wheel radius in meters
        if not physics.wheels:
            return 0.0
        wheel_radius = physics.wheels[0].radius / 100.0

        # Speed in m/s
        max_speed_ms = (
            (max_rpm / 60.0)
            * (1.0 / (final_ratio * min_gear_ratio))
            * (2.0 * math.pi * wheel_radius)
        )

        # Convert to mph
        ms_to_mph = 2.23694
        return float(max_speed_ms * ms_to_mph)
    except Exception as e:
        print(f"Error calculating max speed: {e}")
        return 0.0


_wheel_ticks = {
    "fl": 0.0,
    "fr": 0.0,
    "rr": 0.0,
    "rl": 0.0,
}
_wheel_tick_reset_count = 0
_wheel_tick_last_timestamp = None
_wheel_tick_last_vehicle_id = None

TICKS_PER_REVOLUTION = 50.0  # 50 ticks per full wheel rotation
DEFAULT_WHEEL_RADIUS_M = 0.33
DEFAULT_WHEELBASE_M = 2.50
DEFAULT_TRACK_WIDTH_M = 1.50


def reset_wheel_ticks():
    """Explicitly increments reset_count and resets cumulative wheel tick counters."""
    global _wheel_tick_reset_count, _wheel_ticks, _wheel_tick_last_timestamp
    _wheel_tick_reset_count += 1
    _wheel_ticks["fl"] = 0.0
    _wheel_ticks["fr"] = 0.0
    _wheel_ticks["rr"] = 0.0
    _wheel_ticks["rl"] = 0.0
    _wheel_tick_last_timestamp = None


def get_wheel_tick_data(vehicle):
    """Calculates and returns cumulative differential wheel ticks for AAOS VHAL.

    Returns:
        tuple: (reset_count: int, fl_ticks: int, fr_ticks: int, rr_ticks: int, rl_ticks: int)
        Note: The return order matches the AAOS standard (FL, FR, RR, RL).
    """
    global _wheel_ticks, _wheel_tick_reset_count, _wheel_tick_last_timestamp, _wheel_tick_last_vehicle_id

    current_time = time.time()

    if not vehicle or not vehicle.is_alive:
        _wheel_tick_last_timestamp = current_time
        return (
            _wheel_tick_reset_count,
            int(round(_wheel_ticks["fl"])),
            int(round(_wheel_ticks["fr"])),
            int(round(_wheel_ticks["rr"])),
            int(round(_wheel_ticks["rl"])),
        )

    # Detect vehicle change or respawn
    if _wheel_tick_last_vehicle_id != vehicle.id:
        if _wheel_tick_last_vehicle_id is not None:
            _wheel_tick_reset_count += 1
            _wheel_ticks["fl"] = 0.0
            _wheel_ticks["fr"] = 0.0
            _wheel_ticks["rr"] = 0.0
            _wheel_ticks["rl"] = 0.0
        _wheel_tick_last_vehicle_id = vehicle.id
        _wheel_tick_last_timestamp = current_time
        return (
            _wheel_tick_reset_count,
            0,
            0,
            0,
            0,
        )

    if _wheel_tick_last_timestamp is None:
        _wheel_tick_last_timestamp = current_time
        return (
            _wheel_tick_reset_count,
            int(round(_wheel_ticks["fl"])),
            int(round(_wheel_ticks["fr"])),
            int(round(_wheel_ticks["rr"])),
            int(round(_wheel_ticks["rl"])),
        )

    dt = current_time - _wheel_tick_last_timestamp
    _wheel_tick_last_timestamp = current_time

    if dt <= 0.0 or dt > 1.0:
        dt = 0.05

    # 1. Linear velocity magnitude (m/s) and forward direction
    v_vec = vehicle.get_velocity()
    speed_ms = math.sqrt(v_vec.x**2 + v_vec.y**2 + v_vec.z**2)

    control = vehicle.get_control()
    is_reverse = control.gear == -1
    direction_sign = -1.0 if is_reverse else 1.0

    # 2. Extract vehicle geometry and wheel radius
    wheelbase = DEFAULT_WHEELBASE_M
    track_width = DEFAULT_TRACK_WIDTH_M
    wheel_radius = DEFAULT_WHEEL_RADIUS_M

    try:
        physics = vehicle.get_physics_control()
        if physics.wheels and len(physics.wheels) >= 4:
            wheel_radius = physics.wheels[0].radius / 100.0  # cm to m
            w_fl = physics.wheels[0].position
            w_fr = physics.wheels[1].position
            w_rl = physics.wheels[2].position
            track_width = abs(w_fl.y - w_fr.y) / 100.0
            wheelbase = abs(w_fl.x - w_rl.x) / 100.0
            if track_width < 0.5:
                track_width = DEFAULT_TRACK_WIDTH_M
            if wheelbase < 0.5:
                wheelbase = DEFAULT_WHEELBASE_M
    except Exception:
        pass

    # 3. Steering angle (radians)
    max_steer_deg = 70.0
    try:
        physics = vehicle.get_physics_control()
        if physics.wheels:
            max_steer_deg = physics.wheels[0].max_steer_angle
    except Exception:
        pass

    steer_rad = math.radians(control.steer * max_steer_deg)

    # 4. Kinematic differential speeds
    if abs(steer_rad) < 1e-4:
        v_fl = speed_ms
        v_fr = speed_ms
        v_rl = speed_ms
        v_rr = speed_ms
    else:
        R = wheelbase / math.tan(steer_rad)
        abs_R = abs(R)

        if steer_rad > 0:  # Right turn
            R_rl = abs_R + track_width / 2.0  # Outer (Left)
            R_rr = max(abs_R - track_width / 2.0, 0.1)  # Inner (Right)
            v_rl = speed_ms * (R_rl / abs_R)
            v_rr = speed_ms * (R_rr / abs_R)
            v_fl = speed_ms * (math.sqrt(R_rl**2 + wheelbase**2) / abs_R)
            v_fr = speed_ms * (math.sqrt(R_rr**2 + wheelbase**2) / abs_R)
        else:  # Left turn
            R_rl = max(abs_R - track_width / 2.0, 0.1)  # Inner (Left)
            R_rr = abs_R + track_width / 2.0  # Outer (Right)
            v_rl = speed_ms * (R_rl / abs_R)
            v_rr = speed_ms * (R_rr / abs_R)
            v_fl = speed_ms * (math.sqrt(R_rl**2 + wheelbase**2) / abs_R)
            v_fr = speed_ms * (math.sqrt(R_rr**2 + wheelbase**2) / abs_R)

    # 5. Calculate delta ticks per wheel
    circumference = 2.0 * math.pi * wheel_radius
    ticks_per_meter = TICKS_PER_REVOLUTION / circumference

    delta_fl = direction_sign * v_fl * dt * ticks_per_meter
    delta_fr = direction_sign * v_fr * dt * ticks_per_meter
    delta_rr = direction_sign * v_rr * dt * ticks_per_meter
    delta_rl = direction_sign * v_rl * dt * ticks_per_meter

    _wheel_ticks["fl"] += delta_fl
    _wheel_ticks["fr"] += delta_fr
    _wheel_ticks["rr"] += delta_rr
    _wheel_ticks["rl"] += delta_rl

    return (
        _wheel_tick_reset_count,
        int(round(_wheel_ticks["fl"])),
        int(round(_wheel_ticks["fr"])),
        int(round(_wheel_ticks["rr"])),
        int(round(_wheel_ticks["rl"])),
    )
