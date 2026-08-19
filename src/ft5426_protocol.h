/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef FT5426_PROTOCOL_H
#define FT5426_PROTOCOL_H

#ifdef __KERNEL__
#include <linux/errno.h>
#include <linux/stddef.h>
#include <linux/types.h>
#else
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#endif

#define FT5426_MAX_POINTS	5
#define FT5426_MAX_X		800
#define FT5426_MAX_Y		480
#define FT5426_BYTES_PER_POINT	6

struct ft5426_point {
	u16 x;
	u16 y;
	u8 id;
	bool active;
};

struct ft5426_frame {
	u8 count;
	struct ft5426_point points[FT5426_MAX_POINTS];
};

static inline int ft5426_parse_frame(const u8 *frame, size_t len,
				     struct ft5426_frame *out)
{
	u8 count;
	u8 i;

	if (!out)
		return -EINVAL;

	*out = (struct ft5426_frame) { 0 };
	if (!frame || len < 1)
		return -EINVAL;

	count = frame[0] & 0x0f;
	if (count > FT5426_MAX_POINTS ||
	    len < 1 + (size_t)count * FT5426_BYTES_PER_POINT)
		return -EINVAL;

	out->count = count;
	for (i = 0; i < count; i++) {
		const u8 *point = &frame[1 + i * FT5426_BYTES_PER_POINT];
		u8 event = point[0] >> 6;
		u16 x = ((point[0] & 0x0f) << 8) | point[1];
		u8 id = point[2] >> 4;
		u16 y = ((point[2] & 0x0f) << 8) | point[3];

		if (id > 14 || x >= FT5426_MAX_X || y >= FT5426_MAX_Y) {
			*out = (struct ft5426_frame) { 0 };
			return -EINVAL;
		}

		out->points[i].id = id;
		out->points[i].x = x;
		out->points[i].y = y;
		out->points[i].active = event == 0 || event == 2;
	}

	return 0;
}

#endif /* FT5426_PROTOCOL_H */
