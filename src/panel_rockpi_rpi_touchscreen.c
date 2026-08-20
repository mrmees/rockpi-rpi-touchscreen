// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright © 2016-2017 Broadcom
 * Copyright (C) 2013, NVIDIA Corporation. All rights reserved.
 * Copyright (c) 2022 Radxa Computer Co., Ltd.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published
 * by the Free Software Foundation.
 *
 * Portions of this file derived from panel-simple.c are provided under the
 * following permission notice:
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *
 * Modified 2026-08-19 by the Rock Pi RPi Touchscreen contributors for an
 * RK3399-safe panel lifecycle, current kernel APIs, and complete error
 * propagation.
 *
 * Upstream mode and MCU lifecycle source:
 * https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/gpu/drm/panel/panel-raspberrypi-touchscreen.c
 * Radxa RK3399 TC358762 command sequence and DSI flags source:
 * https://github.com/radxa/kernel/blob/c681d6a31c2289dbaca2e1f822bab41530fc0f68/drivers/gpu/drm/panel/panel-raspits-tc358762.c
 */

#include <linux/backlight.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/media-bus-format.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_graph.h>

#include <drm/drm_connector.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

#include "display_compat.h"

#define ROCKPI_PANEL_DSI_NAME	"rockpi-rpi-panel"
#define ROCKPI_PANEL_READY_RETRIES	100

enum rockpi_mcu_register {
	REG_ID = 0x80,
	REG_PORTA = 0x81,
	REG_PORTB = 0x82,
	REG_PORTC = 0x83,
	REG_PORTD = 0x84,
	REG_POWERON = 0x85,
	REG_PWM = 0x86,
};

struct rockpi_rpi_panel {
	struct i2c_client *i2c;
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct backlight_device *backlight;
	struct rockpi_display_compat *display_compat;
	bool prepared;
	bool enabled;
	bool compat_applied;
};

static int rockpi_mcu_read(struct rockpi_rpi_panel *ctx, u8 reg)
{
	return i2c_smbus_read_byte_data(ctx->i2c, reg);
}

static int rockpi_mcu_write(struct rockpi_rpi_panel *ctx, u8 reg, u8 value)
{
	return i2c_smbus_write_byte_data(ctx->i2c, reg, value);
}

static int rockpi_tc358762_write(struct rockpi_rpi_panel *ctx,
				 const u8 data[6])
{
	ssize_t ret;

	ret = mipi_dsi_generic_write(ctx->dsi, data, 6);
	if (ret < 0)
		dev_err(&ctx->dsi->dev, "TC358762 write failed: %zd\n", ret);

	return ret < 0 ? ret : 0;
}

static int rockpi_tc358762_init(struct rockpi_rpi_panel *ctx)
{
	static const u8 sequence[][6] = {
		{ 0x10, 0x02, 0x03, 0x00, 0x00, 0x00 },
		{ 0x64, 0x01, 0x0c, 0x00, 0x00, 0x00 },
		{ 0x68, 0x01, 0x0c, 0x00, 0x00, 0x00 },
		{ 0x44, 0x01, 0x00, 0x00, 0x00, 0x00 },
		{ 0x48, 0x01, 0x00, 0x00, 0x00, 0x00 },
		{ 0x14, 0x01, 0x15, 0x00, 0x00, 0x00 },
		{ 0x50, 0x04, 0x60, 0x00, 0x00, 0x00 },
		{ 0x20, 0x04, 0x52, 0x01, 0x10, 0x00 },
		{ 0x24, 0x04, 0x14, 0x00, 0x1a, 0x00 },
		{ 0x28, 0x04, 0x20, 0x03, 0x69, 0x00 },
		{ 0x2c, 0x04, 0x02, 0x00, 0x15, 0x00 },
		{ 0x30, 0x04, 0xe0, 0x01, 0x07, 0x00 },
		{ 0x34, 0x04, 0x01, 0x00, 0x00, 0x00 },
		{ 0x64, 0x04, 0x0f, 0x04, 0x00, 0x00 },
		{ 0x04, 0x01, 0x01, 0x00, 0x00, 0x00 },
		{ 0x04, 0x02, 0x01, 0x00, 0x00, 0x00 },
		{ 0x10, 0x04, 0x03, 0x00, 0x00, 0x00 },
	};
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(sequence); i++) {
		ret = rockpi_tc358762_write(ctx, sequence[i]);
		if (ret)
			return ret;
	}

	usleep_range(10, 20);
	return 0;
}

static int rockpi_backlight_set(struct rockpi_rpi_panel *ctx, u8 brightness)
{
	return rockpi_mcu_write(ctx, REG_PWM, brightness);
}

static int rockpi_panel_force_off(struct rockpi_rpi_panel *ctx)
{
	int first_error;
	int ret;

	first_error = rockpi_mcu_write(ctx, REG_PWM, 0);
	if (first_error)
		dev_err(&ctx->i2c->dev,
			"failed to force inherited backlight off: %d\n",
			first_error);

	ret = rockpi_mcu_write(ctx, REG_POWERON, 0);
	if (ret) {
		dev_err(&ctx->i2c->dev,
			"failed to force inherited panel power off: %d\n", ret);
		if (!first_error)
			first_error = ret;
	}

	return first_error;
}

static int rockpi_backlight_update_status(struct backlight_device *backlight)
{
	struct rockpi_rpi_panel *ctx = bl_get_data(backlight);
	int brightness;
	int ret;

	if (!READ_ONCE(ctx->prepared) || !READ_ONCE(ctx->enabled))
		brightness = 0;
	else
		brightness = backlight_get_brightness(backlight);

	ret = rockpi_backlight_set(ctx, brightness);
	if (ret)
		dev_err(&ctx->i2c->dev, "failed to update backlight PWM: %d\n",
			ret);

	return ret;
}

static const struct backlight_ops rockpi_backlight_ops = {
	.options = BL_CORE_SUSPENDRESUME,
	.update_status = rockpi_backlight_update_status,
};

static const struct drm_display_mode rockpi_panel_mode = {
	.clock = 25979,
	.hdisplay = 800,
	.hsync_start = 801,
	.hsync_end = 803,
	.htotal = 849,
	.vdisplay = 480,
	.vsync_start = 487,
	.vsync_end = 489,
	.vtotal = 510,
	.flags = DRM_MODE_FLAG_NHSYNC | DRM_MODE_FLAG_NVSYNC,
};

static inline struct rockpi_rpi_panel *
to_rockpi_panel(struct drm_panel *panel)
{
	return container_of(panel, struct rockpi_rpi_panel, panel);
}

static int rockpi_panel_prepare(struct drm_panel *panel)
{
	struct rockpi_rpi_panel *ctx = to_rockpi_panel(panel);
	int power_off_ret;
	int ret;
	int i;

	if (READ_ONCE(ctx->prepared))
		return 0;

	ret = rockpi_mcu_write(ctx, REG_POWERON, 1);
	if (ret) {
		dev_err(panel->dev, "failed to power on panel: %d\n", ret);
		return ret;
	}

	for (i = 0; i < ROCKPI_PANEL_READY_RETRIES; i++) {
		ret = rockpi_mcu_read(ctx, REG_PORTB);
		if (ret < 0) {
			dev_err(panel->dev,
				"failed to read panel ready state: %d\n", ret);
			goto power_off;
		}
		if (ret & BIT(0)) {
			break;
		}
		usleep_range(1000, 2000);
	}

	if (i == ROCKPI_PANEL_READY_RETRIES)
		dev_warn(panel->dev,
			 "panel ready bit did not assert; continuing after bounded wait\n");

	ret = rockpi_tc358762_init(ctx);
	if (ret) {
		dev_err(panel->dev, "failed to initialize TC358762: %d\n", ret);
		goto power_off;
	}

	WRITE_ONCE(ctx->prepared, true);
	return 0;

power_off:
	power_off_ret = rockpi_mcu_write(ctx, REG_POWERON, 0);
	if (power_off_ret)
		dev_err(panel->dev,
			"failed to power off after prepare error: %d\n",
			power_off_ret);

	return ret;
}

static int rockpi_panel_enable(struct drm_panel *panel)
{
	struct rockpi_rpi_panel *ctx = to_rockpi_panel(panel);
	int disable_ret;
	int ret;

	if (READ_ONCE(ctx->enabled))
		return 0;
	if (!READ_ONCE(ctx->prepared)) {
		dev_err(panel->dev, "cannot enable an unprepared panel\n");
		return -EPERM;
	}

	ret = rockpi_display_compat_apply(ctx->display_compat);
	if (ret) {
		dev_err(panel->dev,
			"failed to apply display compatibility: %d\n", ret);
		return ret;
	}
	WRITE_ONCE(ctx->compat_applied, true);

	WRITE_ONCE(ctx->enabled, true);
	ret = backlight_device_set_brightness(ctx->backlight, 255);
	if (ret) {
		dev_err(panel->dev, "failed to set backlight brightness: %d\n",
			ret);
		goto disable_backlight;
	}

	ret = backlight_enable(ctx->backlight);
	if (ret) {
		dev_err(panel->dev, "failed to enable backlight: %d\n", ret);
		goto disable_backlight;
	}

	ret = rockpi_mcu_write(ctx, REG_PORTA, BIT(2));
	if (ret) {
		dev_err(panel->dev, "failed to set panel orientation: %d\n", ret);
		goto disable_backlight;
	}

	return 0;

disable_backlight:
	WRITE_ONCE(ctx->enabled, false);
	disable_ret = backlight_disable(ctx->backlight);
	if (disable_ret)
		dev_err(panel->dev,
			"failed to disable backlight after enable error: %d\n",
			disable_ret);
	rockpi_display_compat_restore(ctx->display_compat);
	WRITE_ONCE(ctx->compat_applied, false);
	return ret;
}

static int rockpi_panel_disable(struct drm_panel *panel)
{
	struct rockpi_rpi_panel *ctx = to_rockpi_panel(panel);
	int ret;

	WRITE_ONCE(ctx->enabled, false);
	ret = backlight_disable(ctx->backlight);
	if (ret)
		dev_err(panel->dev, "failed to disable backlight: %d\n", ret);
	if (READ_ONCE(ctx->compat_applied)) {
		rockpi_display_compat_restore(ctx->display_compat);
		WRITE_ONCE(ctx->compat_applied, false);
	}

	return ret;
}

static int rockpi_panel_unprepare(struct drm_panel *panel)
{
	struct rockpi_rpi_panel *ctx = to_rockpi_panel(panel);
	int ret;

	WRITE_ONCE(ctx->prepared, false);
	ret = rockpi_mcu_write(ctx, REG_POWERON, 0);
	if (ret)
		dev_err(panel->dev, "failed to power off panel: %d\n", ret);

	return ret;
}

static int rockpi_panel_get_modes(struct drm_panel *panel,
				  struct drm_connector *connector)
{
	static const u32 bus_format = MEDIA_BUS_FMT_RGB888_1X24;
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &rockpi_panel_mode);
	if (!mode) {
		dev_err(panel->dev, "failed to add 800x480 mode\n");
		return -ENOMEM;
	}

	mode->type |= DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	drm_mode_set_name(mode);
	drm_mode_probed_add(connector, mode);

	connector->display_info.bpc = 8;
	connector->display_info.width_mm = 154;
	connector->display_info.height_mm = 86;
	drm_display_info_set_bus_formats(&connector->display_info,
					 &bus_format, 1);

	return 1;
}

static const struct drm_panel_funcs rockpi_panel_funcs = {
	.prepare = rockpi_panel_prepare,
	.enable = rockpi_panel_enable,
	.disable = rockpi_panel_disable,
	.unprepare = rockpi_panel_unprepare,
	.get_modes = rockpi_panel_get_modes,
};

static int rockpi_panel_stop(struct rockpi_rpi_panel *ctx)
{
	int first_error;
	int ret;

	first_error = rockpi_panel_disable(&ctx->panel);
	if (first_error)
		dev_err(&ctx->i2c->dev, "failed to disable panel: %d\n",
			first_error);

	ret = rockpi_panel_unprepare(&ctx->panel);
	if (ret) {
		dev_err(&ctx->i2c->dev, "failed to unprepare panel: %d\n", ret);
		if (!first_error)
			first_error = ret;
	}

	return first_error;
}

static int rockpi_panel_probe(struct i2c_client *i2c)
{
	struct backlight_properties backlight_props = {
		.type = BACKLIGHT_RAW,
		.max_brightness = 255,
		.brightness = 255,
		.power = BACKLIGHT_POWER_OFF,
		.state = BL_CORE_FBBLANK,
	};
	struct mipi_dsi_device_info dsi_info = {
		.type = ROCKPI_PANEL_DSI_NAME,
		.channel = 0,
	};
	struct device_node *dsi_host_node;
	struct device_node *endpoint;
	struct mipi_dsi_host *host;
	struct rockpi_rpi_panel *ctx;
	struct device *dev = &i2c->dev;
	int id;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct rockpi_rpi_panel, panel,
				   &rockpi_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ctx->i2c = i2c;
	i2c_set_clientdata(i2c, ctx);

	id = rockpi_mcu_read(ctx, REG_ID);
	if (id < 0)
		return dev_err_probe(dev, id, "failed to read MCU ID\n");
	if (id != 0xc3)
		return dev_err_probe(dev, -ENODEV,
				     "unexpected MCU ID 0x%02x\n", id);

	ret = rockpi_panel_force_off(ctx);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to establish safe initial state\n");

	endpoint = of_graph_get_endpoint_by_regs(dev->of_node, 0, -1);
	if (!endpoint)
		return dev_err_probe(dev, -ENODEV,
				     "missing panel DSI endpoint\n");

	dsi_host_node = of_graph_get_remote_port_parent(endpoint);
	if (!dsi_host_node) {
		ret = -ENODEV;
		goto put_endpoint;
	}

	host = of_find_mipi_dsi_host_by_node(dsi_host_node);
	of_node_put(dsi_host_node);
	if (!host) {
		ret = -EPROBE_DEFER;
		goto put_endpoint;
	}

	dsi_info.node = of_graph_get_remote_port(endpoint);
	if (!dsi_info.node) {
		ret = -ENODEV;
		goto put_endpoint;
	}

	of_node_put(endpoint);
	ctx->dsi = mipi_dsi_device_register_full(host, &dsi_info);
	if (IS_ERR(ctx->dsi)) {
		ret = PTR_ERR(ctx->dsi);
		of_node_put(dsi_info.node);
		return dev_err_probe(dev, ret,
				     "failed to register DSI device\n");
	}

	ctx->dsi->lanes = 1;
	ctx->dsi->format = MIPI_DSI_FMT_RGB888;
	ctx->dsi->mode_flags = MIPI_DSI_MODE_VIDEO |
		MIPI_DSI_MODE_VIDEO_BURST | MIPI_DSI_MODE_LPM;

	ctx->backlight = backlight_device_register("rockpi-rpi-touchscreen",
						   dev, ctx,
						   &rockpi_backlight_ops,
						   &backlight_props);
	if (IS_ERR(ctx->backlight)) {
		ret = PTR_ERR(ctx->backlight);
		goto unregister_dsi;
	}

	/* TC358762 commands in prepare() require the DSI host in LP-11. */
	ctx->panel.prepare_prev_first = true;
	ctx->display_compat = rockpi_display_compat_get(dev);
	if (IS_ERR(ctx->display_compat)) {
		ret = PTR_ERR(ctx->display_compat);
		goto unregister_backlight;
	}

	/* The DesignWare host resolves the graph bridge during attach. */
	drm_panel_add(&ctx->panel);

	ret = mipi_dsi_attach(ctx->dsi);
	if (ret)
		goto remove_panel;

	dev_info(dev, "registered RK3399-safe Raspberry Pi touchscreen panel\n");
	return 0;

remove_panel:
	drm_panel_remove(&ctx->panel);
	rockpi_display_compat_put(ctx->display_compat);
unregister_backlight:
	backlight_device_unregister(ctx->backlight);
unregister_dsi:
	mipi_dsi_device_unregister(ctx->dsi);
	return dev_err_probe(dev, ret, "failed to initialize panel\n");

put_endpoint:
	of_node_put(endpoint);
	return dev_err_probe(dev, ret, "failed to locate DSI host\n");
}

static void rockpi_panel_remove(struct i2c_client *i2c)
{
	struct rockpi_rpi_panel *ctx = i2c_get_clientdata(i2c);
	int ret;

	ret = rockpi_panel_stop(ctx);
	if (ret)
		dev_err(&i2c->dev, "panel stop failed during remove: %d\n", ret);

	ret = mipi_dsi_detach(ctx->dsi);
	if (ret)
		dev_err(&i2c->dev, "failed to detach DSI device: %d\n", ret);
	drm_panel_remove(&ctx->panel);
	rockpi_display_compat_put(ctx->display_compat);
	backlight_device_unregister(ctx->backlight);
	mipi_dsi_device_unregister(ctx->dsi);
}

static void rockpi_panel_shutdown(struct i2c_client *i2c)
{
	struct rockpi_rpi_panel *ctx = i2c_get_clientdata(i2c);
	int ret;

	ret = rockpi_panel_stop(ctx);
	if (ret)
		dev_err(&i2c->dev, "panel stop failed during shutdown: %d\n", ret);
}

static const struct of_device_id rockpi_panel_of_match[] = {
	{ .compatible = "rockpi,rpi-7inch-touchscreen-panel" },
	{ }
};
MODULE_DEVICE_TABLE(of, rockpi_panel_of_match);

static struct i2c_driver rockpi_panel_driver = {
	.driver = {
		.name = "panel_rockpi_rpi_touchscreen",
		.of_match_table = rockpi_panel_of_match,
	},
	.probe = rockpi_panel_probe,
	.remove = rockpi_panel_remove,
	.shutdown = rockpi_panel_shutdown,
};
module_i2c_driver(rockpi_panel_driver);

MODULE_AUTHOR("Rock Pi RPi Touchscreen contributors");
MODULE_DESCRIPTION("RK3399-safe Raspberry Pi 7-inch touchscreen panel driver");
MODULE_LICENSE("GPL v2");
