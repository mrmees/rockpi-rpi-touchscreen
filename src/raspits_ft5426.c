// SPDX-License-Identifier: GPL-2.0-only
/*
 * Raspberry Pi 7 inch Touchscreen FT5426 touch driver.
 *
 * Copyright (c) 2016 ASUSTek Computer Inc.
 * Copyright (c) 2012-2014, The Linux Foundation. All rights reserved.
 *
 * Modified 2026 by the Rock Pi RPi Touchscreen contributors for current
 * kernels, bounded parsing, polling error recovery, and safe lifecycle use.
 */
#include <linux/bitops.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include "ft5426_protocol.h"

#define FT5426_REG_TOUCH_STATUS	0x02
#define FT5426_REG_FW_VERSION		0xa6
#define FT5426_REG_FW_MINOR		0xb2
#define FT5426_REG_FW_SUBMINOR		0xb3
#define FT5426_FRAME_SIZE		(1 + FT5426_MAX_POINTS * FT5426_BYTES_PER_POINT)
#define FT5426_POLL_INTERVAL_MS	17
#define FT5426_MAX_CONSECUTIVE_FAILURES	3

struct raspits_ft5426 {
	struct i2c_client *client;
	struct input_dev *input;
	struct delayed_work poll_work;
	unsigned long active_ids;
	u8 consecutive_failures;
	bool stopping;
};

static void raspits_release_active_touches(struct raspits_ft5426 *ts)
{
	unsigned long active_ids = ts->active_ids;
	unsigned int id;

	for_each_set_bit(id, &active_ids, 15) {
		int slot = input_mt_get_slot_by_key(ts->input, id);

		if (slot < 0)
			continue;
		input_mt_slot(ts->input, slot);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
	}
	ts->active_ids = 0;
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
}

static void raspits_poll_failed(struct raspits_ft5426 *ts)
{
	if (ts->consecutive_failures < FT5426_MAX_CONSECUTIVE_FAILURES)
		ts->consecutive_failures++;
	if (ts->consecutive_failures == FT5426_MAX_CONSECUTIVE_FAILURES &&
	    ts->active_ids)
		raspits_release_active_touches(ts);
}

static void raspits_poll(struct work_struct *work)
{
	struct raspits_ft5426 *ts = container_of(to_delayed_work(work),
						 struct raspits_ft5426, poll_work);
	struct ft5426_frame frame;
	unsigned long next_active_ids = 0;
	unsigned long released_ids;
	u8 raw[FT5426_FRAME_SIZE];
	unsigned int id;
	int ret;
	u8 i;

	if (READ_ONCE(ts->stopping))
		return;

	ret = i2c_smbus_read_i2c_block_data(ts->client,
					    FT5426_REG_TOUCH_STATUS,
					    sizeof(raw), raw);
	if (ret != sizeof(raw)) {
		raspits_poll_failed(ts);
		goto reschedule;
	}

	if (ft5426_parse_frame(raw, sizeof(raw), &frame)) {
		raspits_poll_failed(ts);
		goto reschedule;
	}
	ts->consecutive_failures = 0;

	for (i = 0; i < frame.count; i++) {
		const struct ft5426_point *point = &frame.points[i];
		int slot;

		if (!point->active)
			continue;

		slot = input_mt_get_slot_by_key(ts->input, point->id);
		if (slot < 0)
			continue;

		input_mt_slot(ts->input, slot);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
		input_report_abs(ts->input, ABS_MT_POSITION_X, point->x);
		input_report_abs(ts->input, ABS_MT_POSITION_Y, point->y);
		__set_bit(point->id, &next_active_ids);
	}

	released_ids = ts->active_ids & ~next_active_ids;
	for_each_set_bit(id, &released_ids, 15) {
		int slot = input_mt_get_slot_by_key(ts->input, id);

		if (slot < 0)
			continue;

		input_mt_slot(ts->input, slot);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
	}

	ts->active_ids = next_active_ids;
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);

reschedule:
	if (!READ_ONCE(ts->stopping))
		schedule_delayed_work(&ts->poll_work,
				      msecs_to_jiffies(FT5426_POLL_INTERVAL_MS));
}

static int raspits_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct raspits_ft5426 *ts;
	struct input_dev *input;
	int fw_version;
	int fw_minor;
	int fw_subminor;
	int ret;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	fw_version = i2c_smbus_read_byte_data(client, FT5426_REG_FW_VERSION);
	if (fw_version < 0)
		return dev_err_probe(dev, fw_version,
				     "unable to read FT5426 firmware version\n");
	fw_minor = i2c_smbus_read_byte_data(client, FT5426_REG_FW_MINOR);
	if (fw_minor < 0)
		return dev_err_probe(dev, fw_minor,
				     "unable to read FT5426 firmware minor\n");
	fw_subminor = i2c_smbus_read_byte_data(client, FT5426_REG_FW_SUBMINOR);
	if (fw_subminor < 0)
		return dev_err_probe(dev, fw_subminor,
				     "unable to read FT5426 firmware subminor\n");

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;

	ts->client = client;
	ts->input = input;
	input->name = "Raspberry Pi 7-inch Touchscreen";
	input->id.bustype = BUS_I2C;

	input_set_abs_params(input, ABS_MT_POSITION_X, 0, FT5426_MAX_X - 1,
			     0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, FT5426_MAX_Y - 1,
			     0, 0);

	ret = input_mt_init_slots(input, FT5426_MAX_POINTS,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;

	ret = input_register_device(input);
	if (ret)
		return ret;

	i2c_set_clientdata(client, ts);
	INIT_DELAYED_WORK(&ts->poll_work, raspits_poll);

	dev_info(dev, "FT5426 firmware 0x%02x.%02x.%02x\n",
		 fw_version, fw_minor, fw_subminor);

	schedule_delayed_work(&ts->poll_work,
			      msecs_to_jiffies(FT5426_POLL_INTERVAL_MS));
	return 0;
}

static void raspits_stop(struct raspits_ft5426 *ts)
{
	WRITE_ONCE(ts->stopping, true);
	cancel_delayed_work_sync(&ts->poll_work);
}

static void raspits_remove(struct i2c_client *client)
{
	struct raspits_ft5426 *ts = i2c_get_clientdata(client);

	raspits_stop(ts);
}

static void raspits_shutdown(struct i2c_client *client)
{
	struct raspits_ft5426 *ts = i2c_get_clientdata(client);

	raspits_stop(ts);
}

static const struct of_device_id raspits_of_match[] = {
	{ .compatible = "raspits_ft5426" },
	{ }
};
MODULE_DEVICE_TABLE(of, raspits_of_match);

static struct i2c_driver raspits_driver = {
	.driver = {
		.name = "raspits_ft5426",
		.of_match_table = raspits_of_match,
	},
	.probe = raspits_probe,
	.remove = raspits_remove,
	.shutdown = raspits_shutdown,
};
module_i2c_driver(raspits_driver);

MODULE_AUTHOR("Rock Pi RPi Touchscreen contributors");
MODULE_DESCRIPTION("Polling FT5426 driver for the Raspberry Pi 7-inch Touchscreen");
MODULE_LICENSE("GPL v2");
