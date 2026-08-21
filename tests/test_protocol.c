#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef uint8_t u8;
typedef uint16_t u16;

#include "src/ft5426_protocol.h"

static void test_two_contacts(void)
{
	const u8 raw[] = { 2,
		0x01, 0x23, 0x11, 0x56, 0, 0,
		0x82, 0x34, 0x21, 0x89, 0, 0 };
	struct ft5426_frame out = { 0 };

	assert(ft5426_parse_frame(raw, sizeof(raw), &out) == 0);
	assert(out.count == 2);
	assert(out.points[0].id == 1 && out.points[0].x == 0x123);
	assert(out.points[0].y == 0x156 && out.points[0].active);
	assert(out.points[1].id == 2 && out.points[1].x == 0x234);
	assert(out.points[1].y == 0x189 && out.points[1].active);
}

static void test_truncated_frame(void)
{
	const u8 raw[] = { 2, 0x01, 0x23, 0x11, 0x56, 0, 0 };
	struct ft5426_frame out = { 0 };

	assert(ft5426_parse_frame(raw, sizeof(raw), &out) != 0);
}

static void test_count_above_five(void)
{
	const u8 raw[] = { 6 };
	struct ft5426_frame out = { 0 };

	assert(ft5426_parse_frame(raw, sizeof(raw), &out) != 0);
}

static void test_id_above_fourteen(void)
{
	const u8 raw[] = { 1, 0x01, 0x23, 0xf1, 0x56, 0, 0 };
	struct ft5426_frame out = { 0 };

	assert(ft5426_parse_frame(raw, sizeof(raw), &out) != 0);
}

static void test_coordinate_outside_800x480(void)
{
	const u8 raw[] = { 1, 0x03, 0x20, 0x11, 0xe0, 0, 0 };
	struct ft5426_frame out = { 0 };

	assert(ft5426_parse_frame(raw, sizeof(raw), &out) != 0);
}

int main(void)
{
	test_two_contacts();
	test_truncated_frame();
	test_count_above_five();
	test_id_above_fourteen();
	test_coordinate_outside_800x480();
	puts("PASS: FT5426 protocol parser");
	return 0;
}
