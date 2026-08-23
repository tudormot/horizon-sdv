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

"""CARLA simulator to SOME/IP bridge service client."""

# pylint: disable=import-error, broad-exception-caught, invalid-name, too-many-locals, too-many-statements, wrong-import-position, wrong-import-order, ungrouped-imports, missing-function-docstring, missing-class-docstring, protected-access, unused-argument, too-many-arguments, too-many-positional-arguments, global-statement

# Monkeypatch: Typing support for python3.7, required by someipy==1.0
import ipaddress
import sys
import typing


try:
    from typing import Protocol, TypedDict
except ImportError:
    from typing_extensions import Protocol
    from typing_extensions import TypedDict

    # Inject into the global typing module
    typing.TypedDict = TypedDict
    typing.Protocol = Protocol

    # Some libraries check sys.modules directly, so we ensure consistency
    sys.modules["typing"].TypedDict = TypedDict
    sys.modules["typing"].Protocol = Protocol

import argparse
import asyncio
from dataclasses import dataclass
from enum import auto
from enum import Enum
import logging
import random
import time
from typing import Tuple

import carla
from get_data_logic import get_ambient_light_data
from get_data_logic import get_automatic_gear_data
from get_data_logic import get_fog_data
from get_data_logic import get_gnss_data
from get_data_logic import get_handbrake_data
from get_data_logic import get_max_speed_data
from get_data_logic import get_odometer_data
from get_data_logic import get_speed_limit_data
from get_data_logic import get_vehicle_acceleration
from get_data_logic import get_vehicle_dynamics
from get_data_logic import get_vehicle_light_data
from get_data_logic import get_vehicle_rpm
from get_data_logic import get_vehicle_speed_miles_h
from get_data_logic import get_wheel_tick_data
from get_data_logic import reset_wheel_ticks
from someipy import construct_server_service_instance
from someipy import EventGroup
from someipy import MessageType
from someipy import MethodResult
from someipy import ReturnCode
from someipy import ServiceBuilder
from someipy import TransportLayerProtocol
import someipy.logging
from someipy.serialization import Bool
from someipy.serialization import Float32
from someipy.serialization import Float64
from someipy.serialization import Sint64
from someipy.serialization import SomeIpPayload
from someipy.serialization import Uint8
from someipy.serialization import Uint32
from someipy.serialization import Uint64
from someipy.service import Method
from someipy.service_discovery import construct_service_discovery


someipy.logging._log_level = logging.INFO


class BridgeMode(Enum):
    ManualWASD = auto()
    ManualWheel = auto()
    Auto = auto()

    @classmethod
    def from_str(cls, mode_str: str) -> "BridgeMode":
        mapping = {
            "manual-wasd": cls.ManualWASD,
            "manual-wheel": cls.ManualWheel,
            "auto": cls.Auto,
        }
        return mapping.get(mode_str.lower(), cls.Auto)


@dataclass
class VehicleSpeedMsg(SomeIpPayload):
    """Used for current speed, speed limit, and max speed.

    Speed values are specified in miles per hour (mph).
    """

    speed: Uint32
    precise_speed: Float32

    def __init__(self, speed_val=0.0):
        self.speed = Uint32(int(speed_val))
        self.precise_speed = Float32(speed_val)


@dataclass
class VehicleRpmMsg(SomeIpPayload):
    rpm: Uint32

    def __init__(self, rpm_val=0):
        self.rpm = Uint32(rpm_val)


@dataclass
class CarlaVehicleDynamicsMsg(SomeIpPayload):
    steering_angle_deg: Float64
    accelerator_pedal_pct: Float64
    brake_pedal_pct: Float64

    def __init__(self, steer=0.0, acc=0.0, brake=0.0):
        self.steering_angle_deg = Float64(steer)
        self.accelerator_pedal_pct = Float64(acc)
        self.brake_pedal_pct = Float64(brake)


@dataclass
class CarlaVehicleAccelerationMsg(SomeIpPayload):
    acceleration_m_s2: Float64

    def __init__(self, acc=0.0):
        self.acceleration_m_s2 = Float64(acc)


@dataclass
class CarlaVehicleOdometerMsg(SomeIpPayload):
    distance_meters: Uint64

    def __init__(self, distance=0):
        self.distance_meters = Uint64(distance)


@dataclass
class CarlaVehicleAmbientLightMsg(SomeIpPayload):
    mode: Bool

    def __init__(self, mode=False):
        self.mode = Bool(mode)


@dataclass
class CarlaAmbientFogMsg(SomeIpPayload):
    is_foggy: Bool

    def __init__(self, foggy=False):
        self.is_foggy = Bool(foggy)


@dataclass
class ShouldDisplaySpeedLimitMsg(SomeIpPayload):
    should_display: Bool

    def __init__(self, should_display=True):
        self.should_display = Bool(should_display)


@dataclass
class CarlaVehicleCurrentAutomaticGearMsg(SomeIpPayload):
    gear: Uint8

    def __init__(self, gear=2):
        self.gear = Uint8(gear)


@dataclass
class CarlaVehicleHandbrakeMsg(SomeIpPayload):
    is_on: Bool

    def __init__(self, is_on=False):
        self.is_on = Bool(is_on)


@dataclass
class CarlaVehicleLightMsg(SomeIpPayload):
    is_on: Bool

    def __init__(self, is_on=False):
        self.is_on = Bool(is_on)


@dataclass
class CarlaVehicleTrunkStatusMsg(SomeIpPayload):
    is_opened: Bool

    def __init__(self, is_opened=False):
        self.is_opened = Bool(False)


@dataclass
class CarlaVehicleAnyDoorStatusMsg(SomeIpPayload):
    is_opened: Bool

    def __init__(self, is_opened=False):
        self.is_opened = Bool(is_opened)


@dataclass
class CarlaWheelTickMsg(SomeIpPayload):
    """Carla wheel ticks formatted for Android Automotive OS (AAOS) WHEEL_TICK INT64_VEC.

    Array ordering: [reset_count, front_left, front_right, rear_right, rear_left]
    """

    reset_count: Sint64
    front_left: Sint64
    front_right: Sint64
    rear_right: Sint64
    rear_left: Sint64

    def __init__(self, reset_count=0, fl=0, fr=0, rr=0, rl=0):
        self.reset_count = Sint64(reset_count)
        self.front_left = Sint64(fl)
        self.front_right = Sint64(fr)
        self.rear_right = Sint64(rr)
        self.rear_left = Sint64(rl)


@dataclass
class GnssMsg(SomeIpPayload):

    latitude: Float64
    longitude: Float64
    altitude: Float64
    speed_m_s: Float64
    bearing: Float64
    timestamp_ms: Uint64

    def __init__(self, lat=0.0, lon=0.0, alt=0.0, speed=0.0, bear=0.0, ts=0):
        self.latitude = Float64(lat)
        self.longitude = Float64(lon)
        self.altitude = Float64(alt)
        self.speed_m_s = Float64(speed)
        self.bearing = Float64(bear)
        self.timestamp_ms = Uint64(ts)


@dataclass
class CarlaCommandRequest(SomeIpPayload):
    command_id: Uint32

    def __init__(self, command_id=0):
        self.command_id = Uint32(command_id)


@dataclass
class CarlaCommandResponse(SomeIpPayload):
    status_code: Uint32

    def __init__(self, status_code=0):
        self.status_code = Uint32(status_code)


DEFAULT_SPAWN_POINT = carla.Transform(
    carla.Location(x=356.560211, y=-288.463104, z=156.336990),
    carla.Rotation(pitch=1.829985, yaw=-139.894669, roll=0.000000)
)


def get_initial_spawn_point(carla_map):
    """Returns the default deterministic spawn point if available in the current map;
    otherwise falls back to a campus-filtered or random spawn point."""
    all_spawns = carla_map.get_spawn_points()
    if not all_spawns:
        return carla.Transform()

    # 1. Deterministic match: look for default spawn point
    for sp in all_spawns:
        if sp.location.distance(DEFAULT_SPAWN_POINT.location) < 2.0:
            return sp

    # 2. Fallback: filter within campus bounds
    CAMPUS_BOUNDS = {"min_x": -560.0, "max_x": 680.0, "min_y": -550.0, "max_y": 650.0}
    campus_spawns = [
        sp
        for sp in all_spawns
        if CAMPUS_BOUNDS["min_x"] <= sp.location.x <= CAMPUS_BOUNDS["max_x"]
        and CAMPUS_BOUNDS["min_y"] <= sp.location.y <= CAMPUS_BOUNDS["max_y"]
    ]
    if campus_spawns:
        return random.choice(campus_spawns)

    return random.choice(all_spawns)


class CarlaSomeipBridge:
    def __init__(
        self,
        carla_host="localhost",
        carla_port=2000,
        mode: BridgeMode = BridgeMode.Auto,
    ):
        self.carla_host = carla_host
        self.carla_port = carla_port
        self.mode = mode
        self.client = None
        self.world = None
        self.vehicle = None
        self.we_spawned_vehicle = False

    async def setup_carla(self):
        """Connects to CARLA and initializes the world."""
        self.client = carla.Client(self.carla_host, self.carla_port)
        self.client.set_timeout(30.0)
        self.world = self.client.get_world()
        await self.acquire_vehicle()
        return self.vehicle

    async def acquire_vehicle(self):
        """Spawns or polls for the vehicle based on mode."""
        if self.mode == BridgeMode.Auto:
            print("Mode: Auto. Spawning new vehicle with autopilot...")
            blueprint = self.world.get_blueprint_library().filter("vehicle.*")[0]
            blueprint.set_attribute("role_name", "hero")

            all_spawns = self.world.get_map().get_spawn_points()
            if not all_spawns:
                raise RuntimeError("No spawn points found in CARLA world")

            spawn_point = get_initial_spawn_point(self.world.get_map())
            self.vehicle = self.world.spawn_actor(blueprint, spawn_point)
            self.vehicle.set_autopilot(True)
            self.we_spawned_vehicle = True
            return self.vehicle

        print(
            f"Mode: {self.mode.name}. Waiting for 'hero' vehicle to be"
            " spawned externally..."
        )
        while True:
            for actor in self.world.get_actors().filter("vehicle.*"):
                if actor.attributes.get("role_name") == "hero":
                    print(f"Found 'hero' vehicle: {actor.type_id} (ID:" f" {actor.id})")
                    self.vehicle = actor
                    self.we_spawned_vehicle = False
                    return self.vehicle
            # Poll faster (every 1s) for better responsiveness during resets
            await asyncio.sleep(1.0)

    def destroy(self):
        if self.vehicle and self.we_spawned_vehicle:
            print(f"Destroying vehicle {self.vehicle.id}")
            self.vehicle.destroy()

    async def handle_generic_command(
        self, payload: bytes, remote_addr: Tuple[str, int]
    ) -> MethodResult:
        """Handler for GenericCarlaCommand method."""
        try:
            request = CarlaCommandRequest().deserialize(payload)
            print(
                f"\nReceived Command ID: {request.command_id.value} from"
                f" {remote_addr}"
            )
            ID_TO_COMMAND[request.command_id.value](self.world, self.vehicle)

            response_payload = CarlaCommandResponse(1).serialize()  # 1 for success
            result = MethodResult()
            result.return_code = ReturnCode.E_OK
            result.message_type = MessageType.RESPONSE
            result.payload = response_payload
            return result
        except Exception as e:
            print(f"Error handling command: {e}")
            result = MethodResult()
            result.return_code = ReturnCode.E_NOT_OK
            result.message_type = MessageType.RESPONSE
            result.payload = CarlaCommandResponse(0).serialize()  # 0 for failure
            return result


def toggle_fog(world, _vehicle):
    if not world:
        return
    weather = world.get_weather()
    if weather.fog_density > 50.0:
        print("Toggling Fog: OFF")
        weather.fog_density = 0.0
    else:
        print("Toggling Fog: ON (Very Foggy)")
        weather.fog_density = 90.0
        weather.fog_distance = 5.0
    world.set_weather(weather)


# TODO(tmot) POC. Figure out how to retrieve from Carla
state_doors_opened = False
state_door_fl_opened = False


def toggle_doors(_world, vehicle):
    global state_doors_opened, state_door_fl_opened
    if state_doors_opened:
        vehicle.close_door(carla.VehicleDoor.All)
        state_doors_opened = False
        # If we close all, FL is also closed
        state_door_fl_opened = False
    else:
        vehicle.open_door(carla.VehicleDoor.All)
        state_doors_opened = True
        state_door_fl_opened = True


def open_all_doors(_world, vehicle):
    global state_doors_opened
    global state_door_fl_opened
    print("Command: Opening all doors")
    vehicle.open_door(carla.VehicleDoor.All)
    state_doors_opened = True
    state_door_fl_opened = True


def close_all_doors(_world, vehicle):
    global state_doors_opened
    global state_door_fl_opened
    print("Command: Closing all doors")
    vehicle.close_door(carla.VehicleDoor.All)
    state_doors_opened = False
    state_door_fl_opened = False


def open_fl_door(_world, vehicle):
    global state_door_fl_opened
    print("Command: Opening front-left door")
    vehicle.open_door(carla.VehicleDoor.FL)
    state_door_fl_opened = True


def close_fl_door(_world, vehicle):
    global state_door_fl_opened
    print("Command: Closing front-left door")
    vehicle.close_door(carla.VehicleDoor.FL)
    state_door_fl_opened = False


def set_light_state(_world, vehicle, light, on=True):
    if not vehicle or not vehicle.is_alive:
        return
    current_state = vehicle.get_light_state()
    if on:
        current_state |= light
    else:
        current_state &= ~light
    vehicle.set_light_state(carla.VehicleLightState(current_state))
    print(f"Command: Light {light} set to {'ON' if on else 'OFF'}")


ID_TO_COMMAND = {
    0: toggle_fog,
    1: toggle_doors,
    2: close_fl_door,  # LOCK
    3: open_fl_door,  # UNLOCK
    4: lambda w, v: set_light_state(w, v, carla.VehicleLightState.Position, True),
    5: lambda w, v: set_light_state(w, v, carla.VehicleLightState.Position, False),
    6: lambda w, v: set_light_state(w, v, carla.VehicleLightState.Fog, True),
    7: lambda w, v: set_light_state(w, v, carla.VehicleLightState.Fog, False),
    8: lambda w, v: set_light_state(w, v, carla.VehicleLightState.LowBeam, True),
    9: lambda w, v: set_light_state(w, v, carla.VehicleLightState.LowBeam, False),
    10: lambda w, v: set_light_state(w, v, carla.VehicleLightState.HighBeam, True),
    11: lambda w, v: set_light_state(w, v, carla.VehicleLightState.HighBeam, False),
}


async def setup_someip_service(bridge: CarlaSomeipBridge):
    """Configures and starts the SOME/IP service offering."""
    SERVICE_ID = 0xCAFE
    INSTANCE_ID = 0x01
    # default ip assigned by CVD to the host (of SDV instances). Carla sim runs on host
    CARLA_SOMEIP_NODE_IP = "192.168.98.1"
    SD_MULTICAST_GROUP = "224.0.0.0"
    SD_PORT = 30490

    # Event IDs
    EVENTGROUP_ID = 0xCAFE
    SPEED_EVENT_ID = 0xCAFE
    GNSS_EVENT_ID = 0xCAF1
    RPM_EVENT_ID = 0xCAF2
    DYNAMICS_EVENT_ID = 0xCAF3
    ODOMETER_EVENT_ID = 0xCAF4
    AMBIENT_LIGHT_EVENT_ID = 0xCAF5
    FOG_EVENT_ID = 0xCAF6
    FOG_LIGHTS_EVENT_ID = 0xCAF7
    PARK_LIGHTS_EVENT_ID = 0xCAF8
    HIBEAM_EVENT_ID = 0xCAF9
    LOWBEAM_EVENT_ID = 0xCAFA
    TURN_SIGNAL_LEFT_EVENT_ID = 0xCAFB
    TURN_SIGNAL_RIGHT_EVENT_ID = 0xCAFC
    SPEED_LIMIT_EVENT_ID = 0xCAFD
    AUTOMATIC_GEAR_EVENT_ID = 0xCB00
    SHOULD_DISPLAY_SPEED_LIMIT_EVENT_ID = 0xCB01
    ACCELERATION_EVENT_ID = 0xCB02
    MAX_SPEED_EVENT_ID = 0xCB03
    HANDBRAKE_EVENT_ID = 0xCB04
    TRUNK_OPENED_EVENT_ID = 0xCB05
    ANY_DOOR_OPENED_EVENT_ID = 0xCB06
    WHEEL_TICK_EVENT_ID = 0xCB07

    speed_eventgroup = EventGroup(
        id=EVENTGROUP_ID,
        event_ids=[
            SPEED_EVENT_ID,
            GNSS_EVENT_ID,
            RPM_EVENT_ID,
            DYNAMICS_EVENT_ID,
            ODOMETER_EVENT_ID,
            AMBIENT_LIGHT_EVENT_ID,
            FOG_EVENT_ID,
            FOG_LIGHTS_EVENT_ID,
            PARK_LIGHTS_EVENT_ID,
            HIBEAM_EVENT_ID,
            LOWBEAM_EVENT_ID,
            TURN_SIGNAL_LEFT_EVENT_ID,
            TURN_SIGNAL_RIGHT_EVENT_ID,
            SPEED_LIMIT_EVENT_ID,
            AUTOMATIC_GEAR_EVENT_ID,
            SHOULD_DISPLAY_SPEED_LIMIT_EVENT_ID,
            ACCELERATION_EVENT_ID,
            MAX_SPEED_EVENT_ID,
            HANDBRAKE_EVENT_ID,
            TRUNK_OPENED_EVENT_ID,
            ANY_DOOR_OPENED_EVENT_ID,
            WHEEL_TICK_EVENT_ID,
        ],
    )

    # Method: Generic Carla Command
    METHOD_ID = 0x8001  # Methods usually start from 0x8000
    generic_command_method = Method(
        id=METHOD_ID, method_handler=bridge.handle_generic_command
    )

    speed_service = (
        ServiceBuilder()
        .with_service_id(SERVICE_ID)
        .with_major_version(1)
        .with_minor_version(0)
        .with_eventgroup(speed_eventgroup)
        .with_method(generic_command_method)
        .build()
    )

    # Setup SD
    service_discovery = await construct_service_discovery(
        SD_MULTICAST_GROUP, SD_PORT, CARLA_SOMEIP_NODE_IP
    )

    service_instance = await construct_server_service_instance(
        speed_service,
        instance_id=INSTANCE_ID,
        endpoint=(
            ipaddress.IPv4Address(CARLA_SOMEIP_NODE_IP),
            3000,
        ),
        ttl=5,
        sd_sender=service_discovery,
        cyclic_offer_delay_ms=2000,
        protocol=TransportLayerProtocol.TCP,
    )

    service_discovery.attach(service_instance)
    service_instance.start_offer()

    return (
        service_instance,
        service_discovery,
        EVENTGROUP_ID,
        SPEED_EVENT_ID,
        GNSS_EVENT_ID,
        RPM_EVENT_ID,
        DYNAMICS_EVENT_ID,
        ODOMETER_EVENT_ID,
        AMBIENT_LIGHT_EVENT_ID,
        FOG_EVENT_ID,
        FOG_LIGHTS_EVENT_ID,
        PARK_LIGHTS_EVENT_ID,
        HIBEAM_EVENT_ID,
        LOWBEAM_EVENT_ID,
        TURN_SIGNAL_LEFT_EVENT_ID,
        TURN_SIGNAL_RIGHT_EVENT_ID,
        SPEED_LIMIT_EVENT_ID,
        AUTOMATIC_GEAR_EVENT_ID,
        SHOULD_DISPLAY_SPEED_LIMIT_EVENT_ID,
        ACCELERATION_EVENT_ID,
        MAX_SPEED_EVENT_ID,
        HANDBRAKE_EVENT_ID,
        TRUNK_OPENED_EVENT_ID,
        ANY_DOOR_OPENED_EVENT_ID,
        WHEEL_TICK_EVENT_ID,
    )


async def run_bridge(mode: BridgeMode = BridgeMode.Auto):
    bridge = CarlaSomeipBridge(mode=mode)
    service_instance = None
    sd = None
    try:
        await bridge.setup_carla()
        (
            service_instance,
            sd,
            eg_id,
            speed_event_id,
            gnss_event_id,
            rpm_event_id,
            dynamics_event_id,
            odometer_event_id,
            ambient_light_event_id,
            fog_event_id,
            fog_lights_ev,
            park_lights_ev,
            hibeam_ev,
            lowbeam_ev,
            turn_left_ev,
            turn_right_ev,
            speed_limit_ev,
            automatic_gear_ev,
            should_display_speed_limit_ev,
            acceleration_ev,
            max_speed_ev,
            handbrake_ev,
            trunk_ev,
            any_door_ev,
            wheel_tick_ev,
        ) = await setup_someip_service(bridge)

        print(
            f"Service offered in mode: {mode.name}. Tracking vehicle:"
            f" {bridge.vehicle.type_id}"
        )

        last_door_state = None

        while True:
            # 0. Check if vehicle is still active. If not, re-acquire.
            if bridge.vehicle is None or not bridge.vehicle.is_alive:
                print("\n[Bridge] Vehicle lost or inactive. Re-acquiring...")
                bridge.vehicle = None
                await bridge.acquire_vehicle()
                print(f"\n[Bridge] Vehicle re-acquired: {bridge.vehicle.type_id}")
                reset_wheel_ticks()
                last_door_state = None  # Reset state to force re-sending

            try:
                # any_door_open is True if either global state OR specific FL state is open
                any_door_open = state_doors_opened or state_door_fl_opened

                # Log door state changes
                if any_door_open != last_door_state:
                    print(f"\n[LOG] Sending Door/Trunk Status: {any_door_open}")
                    last_door_state = any_door_open

                # 1. Vehicle Speed
                speed = get_vehicle_speed_miles_h(bridge.vehicle)
                speed_payload = VehicleSpeedMsg(speed).serialize()
                service_instance.send_event(eg_id, speed_event_id, speed_payload)

                # 2. GNSS Data
                lat, lon, alt, speed_ms, bearing = get_gnss_data(
                    bridge.world, bridge.vehicle
                )
                timestamp_ms = int(time.time() * 1000)
                gnss_payload = GnssMsg(
                    lat, lon, alt, speed_ms, bearing, timestamp_ms
                ).serialize()
                service_instance.send_event(eg_id, gnss_event_id, gnss_payload)

                # 3. Vehicle RPM
                rpm = get_vehicle_rpm(bridge.vehicle)
                rpm_payload = VehicleRpmMsg(rpm).serialize()
                service_instance.send_event(eg_id, rpm_event_id, rpm_payload)

                # 4. Vehicle Dynamics
                steer, acc, brake = get_vehicle_dynamics(bridge.vehicle)
                dynamics_payload = CarlaVehicleDynamicsMsg(
                    steer, acc, brake
                ).serialize()
                service_instance.send_event(eg_id, dynamics_event_id, dynamics_payload)

                # 5. Odometer
                distance_m = get_odometer_data(bridge.vehicle)
                odometer_payload = CarlaVehicleOdometerMsg(distance_m).serialize()
                service_instance.send_event(eg_id, odometer_event_id, odometer_payload)

                # 6. Ambient Light
                ambient_mode = get_ambient_light_data(bridge.world)
                ambient_payload = CarlaVehicleAmbientLightMsg(ambient_mode).serialize()
                service_instance.send_event(
                    eg_id, ambient_light_event_id, ambient_payload
                )

                # 7. Fog
                is_foggy = get_fog_data(bridge.world)
                fog_payload = CarlaAmbientFogMsg(is_foggy).serialize()
                service_instance.send_event(eg_id, fog_event_id, fog_payload)

                # 8. Vehicle Lights
                fog_l, park_l, hibeam, lowbeam, turn_l, turn_r = get_vehicle_light_data(
                    bridge.vehicle
                )
                service_instance.send_event(
                    eg_id, fog_lights_ev, CarlaVehicleLightMsg(fog_l).serialize()
                )
                service_instance.send_event(
                    eg_id, park_lights_ev, CarlaVehicleLightMsg(park_l).serialize()
                )
                service_instance.send_event(
                    eg_id, hibeam_ev, CarlaVehicleLightMsg(hibeam).serialize()
                )
                service_instance.send_event(
                    eg_id, lowbeam_ev, CarlaVehicleLightMsg(lowbeam).serialize()
                )
                service_instance.send_event(
                    eg_id, turn_left_ev, CarlaVehicleLightMsg(turn_l).serialize()
                )
                service_instance.send_event(
                    eg_id, turn_right_ev, CarlaVehicleLightMsg(turn_r).serialize()
                )

                # 9. Speed Limit
                speed_limit = get_speed_limit_data(bridge.vehicle)
                service_instance.send_event(
                    eg_id, speed_limit_ev, VehicleSpeedMsg(speed_limit).serialize()
                )

                # 10. Automatic Gear
                gear_mode = get_automatic_gear_data(bridge.vehicle)
                service_instance.send_event(
                    eg_id,
                    automatic_gear_ev,
                    CarlaVehicleCurrentAutomaticGearMsg(gear_mode).serialize(),
                )

                # 11. Should Display Speed Limit
                service_instance.send_event(
                    eg_id,
                    should_display_speed_limit_ev,
                    ShouldDisplaySpeedLimitMsg(True).serialize(),
                )

                # 12. Acceleration
                accel_val = get_vehicle_acceleration(bridge.vehicle)
                service_instance.send_event(
                    eg_id,
                    acceleration_ev,
                    CarlaVehicleAccelerationMsg(accel_val).serialize(),
                )

                # 13. Max Speed
                max_speed = get_max_speed_data(bridge.vehicle)
                service_instance.send_event(
                    eg_id, max_speed_ev, VehicleSpeedMsg(max_speed).serialize()
                )

                # 14. Handbrake
                handbrake_on = get_handbrake_data(bridge.vehicle)
                service_instance.send_event(
                    eg_id,
                    handbrake_ev,
                    CarlaVehicleHandbrakeMsg(handbrake_on).serialize(),
                )

                # 15. Doors
                service_instance.send_event(
                    eg_id,
                    trunk_ev,
                    CarlaVehicleTrunkStatusMsg(any_door_open).serialize(),
                )
                service_instance.send_event(
                    eg_id,
                    any_door_ev,
                    CarlaVehicleAnyDoorStatusMsg(any_door_open).serialize(),
                )

                # 16. Wheel Ticks (AAOS INT64_VEC: [reset_count, FL, FR, RR, RL])
                reset_cnt, fl_t, fr_t, rr_t, rl_t = get_wheel_tick_data(
                    bridge.vehicle
                )
                wheel_tick_payload = CarlaWheelTickMsg(
                    reset_cnt, fl_t, fr_t, rr_t, rl_t
                ).serialize()
                service_instance.send_event(
                    eg_id, wheel_tick_ev, wheel_tick_payload
                )

                ambient_str = "NIGHT" if ambient_mode else "DAY"
                fog_str = " | FOG" if is_foggy else ""
                gear_map = {0: "P", 1: "R", 2: "N", 3: "D"}
                gear_str = gear_map.get(gear_mode, "?")
                hb_str = " | [HBK]" if handbrake_on else ""
                door_str = f" | DOOR: {'OPENED' if any_door_open else 'CLOSED'}"

                # Create a compact string for lights: Fog, Park, High, Low, Left, Right
                l_fog = "F" if fog_l else "-"
                l_park = "P" if park_l else "-"
                l_hi = "H" if hibeam else "-"
                l_lo = "L" if lowbeam else "-"
                l_left = "<" if turn_l else "-"
                l_right = ">" if turn_r else "-"
                lights_indicator = f"LGT: {l_fog}{l_park}{l_hi}{l_lo}{l_left}{l_right}"

                status_line = (
                    f"SPD: {speed:5.1f} mph | RPM: {rpm:4} | GEAR:"
                    f" {gear_str}{hb_str}{door_str} | ODO: {distance_m:6}m |"
                    f" {ambient_str}{fog_str} | {lights_indicator} | LIM:"
                    f" {speed_limit:2.0f} | MX: {max_speed:3.0f} | STR:"
                    f" {steer:5.1f}° | ACC: {acc:3.0f}% | BRK: {brake:3.0f}% | VAC:"
                    f" {accel_val:4.1f}m/s² | WT: [{fl_t}, {fr_t}, {rr_t}, {rl_t}]"
                    f" (r={reset_cnt}) | TS: {timestamp_ms}"
                )
                print(status_line, end="\r")
            except RuntimeError as re:
                print(
                    f"\n[Bridge] Vehicle interaction error: {re}. Will re-acquire next frame."
                )
                bridge.vehicle = None  # Force re-acquisition

            await asyncio.sleep(0.1)
    except (KeyboardInterrupt, asyncio.CancelledError):
        print("\nShutting down...")
    except Exception as e:
        print(f"\nError: {e}")
    finally:
        if service_instance is not None:
            await service_instance.stop_offer()
        if sd is not None:
            sd.close()
        bridge.destroy()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CARLA SOME/IP Bridge Client")
    parser.add_argument(
        "--mode",
        type=str,
        default="auto",
        help="Operating mode (manual-wasd, manual-wheel, auto)",
    )
    args = parser.parse_args()

    selected_mode = BridgeMode.from_str(args.mode)
    asyncio.run(run_bridge(mode=selected_mode))
