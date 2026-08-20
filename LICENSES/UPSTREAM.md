# Upstream attribution

`src/raspits_ft5426.c` is derived from Radxa's FT5426 polling driver added in
immutable commit `c681d6a31c2289dbaca2e1f822bab41530fc0f68`:

https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/input/touchscreen/raspits_ft5426.c

The original notices are preserved in the modified source:

- Copyright (c) 2016 ASUSTek Computer Inc.
- Copyright (c) 2012-2014, The Linux Foundation. All rights reserved.

The derived driver remains GPL-2.0-only. It was substantially modified in
2026 by the Rock Pi RPi Touchscreen contributors for current kernel APIs,
bounded frame parsing, polling error recovery, and safe lifecycle management.

`src/panel_rockpi_rpi_touchscreen.c` is derived from the upstream Raspberry Pi
panel driver at Linux v6.18 commit
`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`:

https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/gpu/drm/panel/panel-raspberrypi-touchscreen.c

It also uses Radxa's RK3399 TC358762 generic-write sequence and DSI mode flags
from immutable commit `c681d6a31c2289dbaca2e1f822bab41530fc0f68`:

https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/gpu/drm/panel/panel-raspits-tc358762.c

The panel source preserves the relevant notices from both files:

- Copyright © 2016-2017 Broadcom
- Copyright (C) 2013, NVIDIA Corporation. All rights reserved.
- Copyright (c) 2022 Radxa Computer Co., Ltd.

The compatibility driver remains GPL-2.0-only. It was substantially modified
in 2026 by the Rock Pi RPi Touchscreen contributors to send TC358762 commands
during panel prepare after the DesignWare host enters command mode, use current
kernel APIs, and propagate I2C and DSI errors.
