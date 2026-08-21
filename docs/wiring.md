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
4. Keep HDMI available as the recovery display, but begin the authorized
   production acceptance boot with it disconnected; reconnect it only in the
   documented hot-plug sequence after DSI and touch checks pass.

The device-tree overlay supplies the panel controller at I2C address `0x45`
and the touch controller at `0x38`; no separate touch interrupt wire is used.
Install DKMS `0.2.5` before the separately authorized production boot: it supplies exactly three modules in provider, panel, then touch order:
`rockpi_rk3399_display_compat`, `panel_rockpi_rpi_touchscreen`, and
`raspits_ft5426`. The overlay keeps DSI0 disabled as a DRM output while the
compatibility provider uses it only as the DSI1 PLL supplier. Its reciprocal
device-tree route filter constrains DSI to VOPL by graph identity while leaving
HDMI available on VOPB; it does not choose a desktop layout.

Do not change the current display layout, reboot, shut down, or power-cycle
without fresh authorization. On the later production boot, use the README's
physical X11 touch-to-DSI check, persistent crash-log checks, HDMI hot-plug, and
normal desktop mirror/extend and placement checks. A separately authorized
shutdown/cold-start must repeat acceptance later. Keep an SSH or serial
recovery path available; the exact scoped SSH and offline rollback procedures
are in [the recovery guide](recovery.md).

After wiring, follow the [first-boot checks in the README](../README.md#first-authorized-production-boot-hardware-checkpoint).
