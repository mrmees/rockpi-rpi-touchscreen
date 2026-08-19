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
