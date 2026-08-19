# Wiring the original Raspberry Pi 7-inch Touch Display

This wiring is for the original 800x480 Raspberry Pi 7-inch Touch Display and
a Radxa Rock Pi 4B+. It is not wiring guidance for Touch Display 2.

## Safety and orientation

Power off the Rock Pi before inserting or removing the FFC. Do not rely on
hot-plugging the DSI connector, and do not connect or disconnect the GPIO
power leads while the board is powered.

Follow Radxa's published FFC orientation for the Rock Pi 4B+ MIPI DSI connector. The exposed contacts, latch direction, and cable orientation are
board-specific; consult Radxa's board documentation at the connector rather
than copying the Raspberry Pi orientation. Close the latch only after the FFC
is fully seated and aligned.

## Connections

1. With the Rock Pi shut down and unplugged, connect the display's 15-pin DSI
   FFC to the Rock Pi MIPI DSI connector using the orientation above.
2. Connect display power from the 40-pin header. GPIO pin 2 or 4 provides 5 V; GPIO pin 6 is ground. Use one 5 V pin and one ground pin only.
3. Check polarity and connector seating again before applying power.
4. Leave HDMI connected for the first boot so it remains a known-good recovery
   display.

The device-tree overlay supplies the panel controller at I2C address `0x45`
and the touch controller at `0x38`; no separate touch interrupt wire is used.

After wiring, follow the [first-boot checks in the README](../README.md#first-boot-hardware-checkpoint).
