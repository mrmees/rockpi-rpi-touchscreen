/* SPDX-License-Identifier: GPL-2.0-only */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/display_compat_core.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

enum fake_operation {
	FAKE_ENABLE_CLOCKS,
	FAKE_DISABLE_CLOCKS,
	FAKE_ASSERT_RESET,
	FAKE_DEASSERT_RESET,
	FAKE_DELAY_US,
	FAKE_DELAY_MS,
	FAKE_GRF_WRITE,
	FAKE_DSI_READ,
	FAKE_DSI_WRITE,
	FAKE_ROUTE,
	FAKE_VOP_READ,
	FAKE_VOP_WRITE,
};

struct fake_log_entry {
	enum fake_operation operation;
	enum rockpi_vop_id vop;
	rockpi_u32 offset;
	rockpi_u32 value;
	rockpi_u32 extra;
};

struct fake_context {
	rockpi_u32 dsi[64];
	rockpi_u32 vopb[8];
	rockpi_u32 vopl[8];
	struct fake_log_entry log[256];
	size_t log_count;
	enum fake_operation fail_operation;
	int fail_remaining;
	int route_result;
	enum rockpi_vop_id route;
	unsigned int lock_after_reads;
	unsigned int lock_reads;
	bool non_routed_vop_access;
};

static void fail(const char *message)
{
	fprintf(stderr, "FAIL: %s\n", message);
	exit(1);
}

static void expect(bool condition, const char *message)
{
	if (!condition)
		fail(message);
}

static void log_operation(struct fake_context *fake, enum fake_operation operation,
				  enum rockpi_vop_id vop, rockpi_u32 offset,
				  rockpi_u32 value, rockpi_u32 extra)
{
	expect(fake->log_count < ARRAY_SIZE(fake->log), "fake operation log overflow");
	fake->log[fake->log_count++] = (struct fake_log_entry) {
		.operation = operation,
		.vop = vop,
		.offset = offset,
		.value = value,
		.extra = extra,
	};
}

static int fake_result(struct fake_context *fake, enum fake_operation operation)
{
	if (fake->fail_remaining && fake->fail_operation == operation) {
		fake->fail_remaining--;
		return -EIO;
	}
	return 0;
}

static int fake_enable_clocks(void *context)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_ENABLE_CLOCKS, ROCKPI_VOP_BIG, 0, 0, 0);
	return fake_result(fake, FAKE_ENABLE_CLOCKS);
}

static void fake_disable_clocks(void *context)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DISABLE_CLOCKS, ROCKPI_VOP_BIG, 0, 0, 0);
}

static int fake_assert_reset(void *context)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_ASSERT_RESET, ROCKPI_VOP_BIG, 0, 0, 0);
	return fake_result(fake, FAKE_ASSERT_RESET);
}

static int fake_deassert_reset(void *context)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DEASSERT_RESET, ROCKPI_VOP_BIG, 0, 0, 0);
	return fake_result(fake, FAKE_DEASSERT_RESET);
}

static int fake_grf_write(void *context, rockpi_u32 offset, rockpi_u32 value)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_GRF_WRITE, ROCKPI_VOP_BIG, offset, value, 0);
	return fake_result(fake, FAKE_GRF_WRITE);
}

static int fake_dsi_read(void *context, rockpi_u32 offset, rockpi_u32 *value)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DSI_READ, ROCKPI_VOP_BIG, offset, 0, 0);
	if (fake_result(fake, FAKE_DSI_READ))
		return -EIO;
	if (offset == 0x00b0) {
		fake->lock_reads++;
		*value = fake->lock_reads > fake->lock_after_reads ? 1U : 0U;
	} else {
		*value = fake->dsi[offset / 4];
	}
	return 0;
}

static int fake_dsi_write(void *context, rockpi_u32 offset, rockpi_u32 value)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DSI_WRITE, ROCKPI_VOP_BIG, offset, value, 0);
	if (fake_result(fake, FAKE_DSI_WRITE))
		return -EIO;
	fake->dsi[offset / 4] = value;
	return 0;
}

static void fake_delay_us(void *context, rockpi_u32 min, rockpi_u32 max)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DELAY_US, ROCKPI_VOP_BIG, 0, min, max);
}

static void fake_delay_ms(void *context, rockpi_u32 delay)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_DELAY_MS, ROCKPI_VOP_BIG, 0, delay, 0);
}

static int fake_resolve_route(void *context, enum rockpi_vop_id *vop)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_ROUTE, ROCKPI_VOP_BIG, 0, 0, 0);
	if (fake_result(fake, FAKE_ROUTE) || fake->route_result)
		return fake->route_result ? fake->route_result : -EIO;
	*vop = fake->route;
	return 0;
}

static rockpi_u32 *fake_vop_register(struct fake_context *fake,
				      enum rockpi_vop_id vop, rockpi_u32 offset)
{
	if (vop != fake->route) {
		fake->non_routed_vop_access = true;
		fail("fake accessed non-routed VOP");
	}
	return vop == ROCKPI_VOP_BIG ? &fake->vopb[offset / 4] :
		&fake->vopl[offset / 4];
}

static int fake_vop_read(void *context, enum rockpi_vop_id vop,
			 rockpi_u32 offset, rockpi_u32 *value)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_VOP_READ, vop, offset, 0, 0);
	if (fake_result(fake, FAKE_VOP_READ))
		return -EIO;
	*value = *fake_vop_register(fake, vop, offset);
	return 0;
}

static int fake_vop_write(void *context, enum rockpi_vop_id vop,
			  rockpi_u32 offset, rockpi_u32 value)
{
	struct fake_context *fake = context;

	log_operation(fake, FAKE_VOP_WRITE, vop, offset, value, 0);
	if (fake_result(fake, FAKE_VOP_WRITE))
		return -EIO;
	*fake_vop_register(fake, vop, offset) = value;
	return 0;
}

static const struct rockpi_display_io fake_io = {
	.enable_clocks = fake_enable_clocks,
	.disable_clocks = fake_disable_clocks,
	.assert_reset = fake_assert_reset,
	.deassert_reset = fake_deassert_reset,
	.write_dsi0_grf = fake_grf_write,
	.read_dsi0 = fake_dsi_read,
	.write_dsi0 = fake_dsi_write,
	.delay_us = fake_delay_us,
	.delay_ms = fake_delay_ms,
	.resolve_dsi1_vop = fake_resolve_route,
	.read_vop = fake_vop_read,
	.write_vop = fake_vop_write,
};

static void init_fake(struct fake_context *fake, enum rockpi_vop_id route)
{
	memset(fake, 0, sizeof(*fake));
	fake->fail_operation = (enum fake_operation)-1;
	fake->route = route;
	fake->lock_after_reads = 0;
}

static void expect_log(struct fake_context *fake, size_t *index,
		       enum fake_operation operation, rockpi_u32 offset,
		       rockpi_u32 value)
{
	const struct fake_log_entry *entry;

	expect(*index < fake->log_count, "operation log ended early");
	entry = &fake->log[(*index)++];
	expect(entry->operation == operation && entry->offset == offset &&
	       entry->value == value, "DSI0 PHY write sequence differs from proven 780 Mb/s sequence");
}

static void expect_phy_pair(struct fake_context *fake, size_t *index,
			    rockpi_u32 code, rockpi_u32 value)
{
	expect_log(fake, index, FAKE_DSI_WRITE, 0x00b4, 0x00000002);
	expect_log(fake, index, FAKE_DSI_WRITE, 0x00b8, 0x00010000 | code);
	expect_log(fake, index, FAKE_DSI_WRITE, 0x00b4, 0x00000000);
	expect_log(fake, index, FAKE_DSI_WRITE, 0x00b8, value);
	expect_log(fake, index, FAKE_DSI_WRITE, 0x00b4, 0x00000002);
}

static void test_dsi0_start_programs_proven_780mbps_sequence(void)
{
	static const rockpi_u32 phy[][2] = {
		{ 0x10, 0xa3 }, { 0x11, 0x06 }, { 0x12, 0xc4 }, { 0x44, 0x32 },
		{ 0x17, 0x03 }, { 0x18, 0x01 }, { 0x19, 0x30 }, { 0x18, 0x84 },
		{ 0x19, 0x30 }, { 0x22, 0x07 }, { 0x22, 0x87 }, { 0x20, 0x4d },
		{ 0x21, 0x3d }, { 0x21, 0xdf }, { 0x60, 0xb1 }, { 0x61, 0xa0 },
		{ 0x62, 0x5e }, { 0x63, 0xce }, { 0x64, 0x2a }, { 0x65, 0x2d },
		{ 0x70, 0xb1 }, { 0x71, 0xbb }, { 0x72, 0x50 }, { 0x73, 0xb7 },
		{ 0x74, 0x2a },
	};
	struct fake_context fake;
	struct rockpi_dsi0_state state = { 0 };
	size_t index = 0;
	size_t i;

	init_fake(&fake, ROCKPI_VOP_BIG);
	expect(rockpi_dsi0_start(&state, &fake_io, &fake) == 0,
	       "DSI0 start did not succeed");
	expect_log(&fake, &index, FAKE_ENABLE_CLOCKS, 0, 0);
	expect_log(&fake, &index, FAKE_ASSERT_RESET, 0, 0);
	expect_log(&fake, &index, FAKE_DELAY_US, 0, 10);
	expect(fake.log[index - 1].extra == 20, "reset delay must be 10-20 microseconds");
	expect_log(&fake, &index, FAKE_DEASSERT_RESET, 0, 0);
	expect_log(&fake, &index, FAKE_GRF_WRITE, 0x6258, 0xffff0000);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00a0, 0);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00b4, 0);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00b4, 1);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00b4, 0);
	for (i = 0; i < ARRAY_SIZE(phy); i++)
		expect_phy_pair(&fake, &index, phy[i][0], phy[i][1]);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00a4, 0x2000);
	expect_log(&fake, &index, FAKE_DSI_WRITE, 0x00a0, 0x0f);
	expect_log(&fake, &index, FAKE_DSI_READ, 0x00b0, 0);
	expect(index == fake.log_count, "DSI0 start emitted unexpected operations");
	expect(state.clocks_enabled && state.reset_deasserted && state.started,
	       "DSI0 state was not marked started");
}

static void test_dsi0_lock_timeout_unwinds_reset_and_clocks(void)
{
	struct fake_context fake;
	struct rockpi_dsi0_state state = { 0 };
	size_t i;
	unsigned int reads = 0;
	unsigned int delays = 0;

	init_fake(&fake, ROCKPI_VOP_BIG);
	fake.lock_after_reads = 10;
	expect(rockpi_dsi0_start(&state, &fake_io, &fake) == -ETIMEDOUT,
	       "DSI0 lock timeout must return ETIMEDOUT");
	for (i = 0; i < fake.log_count; i++) {
		if (fake.log[i].operation == FAKE_DSI_READ)
			reads++;
		if (fake.log[i].operation == FAKE_DELAY_MS) {
			delays++;
			expect(fake.log[i].value == 1, "DSI0 lock retry delay must be 1 ms");
		}
	}
	expect(reads == 10 && delays == 9, "DSI0 lock poll must stop on tenth miss");
	expect(fake.log[fake.log_count - 3].operation == FAKE_DSI_WRITE &&
	       fake.log[fake.log_count - 3].offset == 0x00a0 &&
	       fake.log[fake.log_count - 3].value == 0,
	       "DSI0 timeout must put PHY in reset before unwinding");
	expect(fake.log[fake.log_count - 2].operation == FAKE_ASSERT_RESET &&
	       fake.log[fake.log_count - 1].operation == FAKE_DISABLE_CLOCKS,
	       "DSI0 timeout must assert reset then disable clocks");
	expect(!state.clocks_enabled && !state.reset_deasserted && !state.started,
	       "DSI0 timeout did not clear state");
}

static void test_dsi0_each_setup_failure_unwinds_completed_steps(void)
{
	static const enum fake_operation failures[] = {
		FAKE_ENABLE_CLOCKS, FAKE_ASSERT_RESET, FAKE_DEASSERT_RESET,
		FAKE_GRF_WRITE, FAKE_DSI_WRITE, FAKE_DSI_READ,
	};
	size_t i;

	for (i = 0; i < ARRAY_SIZE(failures); i++) {
		struct fake_context fake;
		struct rockpi_dsi0_state state = { 0 };

		init_fake(&fake, ROCKPI_VOP_BIG);
		fake.fail_operation = failures[i];
		fake.fail_remaining = 1;
		expect(rockpi_dsi0_start(&state, &fake_io, &fake) == -EIO,
		       "DSI0 setup failure must be returned");
		expect(!state.clocks_enabled && !state.reset_deasserted && !state.started,
		       "DSI0 setup failure did not clear state");
		if (failures[i] != FAKE_ENABLE_CLOCKS)
			expect(fake.log[fake.log_count - 1].operation == FAKE_DISABLE_CLOCKS,
			       "DSI0 setup failure must disable completed clocks");
	}
}

static void init_vop(struct fake_context *fake, enum rockpi_vop_id route)
{
	init_fake(fake, route);
	if (route == ROCKPI_VOP_BIG) {
		fake->vopb[0x0008 / 4] = 0x55550000;
		fake->vopb[0x0010 / 4] = 0xaaaa5000;
	} else {
		fake->vopl[0x0008 / 4] = 0x55550000;
		fake->vopl[0x0010 / 4] = 0xaaaa5000;
	}
}

static void expect_vop_route_only(enum rockpi_vop_id route)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };

	init_vop(&fake, route);
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == 0,
	       "VOP apply failed");
	expect(!fake.non_routed_vop_access && state.selected == route,
	       "VOP apply accessed a non-routed VOP");
}

static void test_vopb_route_accesses_only_vopb(void)
{
	expect_vop_route_only(ROCKPI_VOP_BIG);
}

static void test_vopl_route_accesses_only_vopl(void)
{
	expect_vop_route_only(ROCKPI_VOP_LIT);
}

static void test_route_failure_accesses_neither_vop(void)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };

	init_vop(&fake, ROCKPI_VOP_BIG);
	fake.route_result = -ENODEV;
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == -ENODEV,
	       "route resolution failure was not returned");
	expect(fake.log_count == 1 && fake.log[0].operation == FAKE_ROUTE &&
	       !state.applied, "route failure must access neither VOP");
}

static void test_vop_apply_sets_lane_and_bg_rb_only(void)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };

	init_vop(&fake, ROCKPI_VOP_BIG);
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == 0,
	       "VOP apply failed");
	expect(fake.vopb[0x0008 / 4] == 0x55570000,
	       "VOP apply must set SYS_CTRL data01 swap only");
	expect(fake.vopb[0x0010 / 4] == 0xaaaa3000,
	       "VOP apply must replace DSP_CTRL0 bits 12-14 with BG/RB swap");
	expect(fake.vopb[0] == 1, "VOP apply must write CFG_DONE once");
	expect(state.applied && !state.original_data01_swap &&
	       state.original_rgb_swap == 0x5000,
	       "VOP apply did not retain original fields");
}

static void test_vop_restore_preserves_unrelated_live_changes(void)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };

	init_vop(&fake, ROCKPI_VOP_LIT);
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == 0,
	       "VOP apply failed before restore");
	fake.vopl[0x0008 / 4] = 0x11170004;
	fake.vopl[0x0010 / 4] = 0x22223080;
	fake.log_count = 0;
	rockpi_vop_restore(&state, &fake_io, &fake);
	expect(fake.log_count == 5 && fake.log[0].operation == FAKE_VOP_READ &&
	       fake.log[1].operation == FAKE_VOP_READ &&
	       fake.log[4].operation == FAKE_VOP_WRITE,
	       "VOP restore must read live fields and commit once");
	expect(fake.vopl[0x0008 / 4] == 0x11150004,
	       "VOP restore clobbered unrelated SYS_CTRL changes");
	expect(fake.vopl[0x0010 / 4] == 0x22225080,
	       "VOP restore clobbered unrelated DSP_CTRL0 changes");
	expect(fake.vopl[0] == 1 && !state.applied,
	       "VOP restore did not commit and clear state");
}

static void test_vop_apply_is_idempotent(void)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };
	size_t log_count;

	init_vop(&fake, ROCKPI_VOP_BIG);
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == 0,
	       "initial VOP apply failed");
	log_count = fake.log_count;
	expect(rockpi_vop_apply(&state, &fake_io, &fake) == 0 &&
	       fake.log_count == log_count, "repeated VOP apply must be a no-op");
}

static void test_vop_restore_without_apply_is_noop(void)
{
	struct fake_context fake;
	struct rockpi_vop_state state = { 0 };

	init_vop(&fake, ROCKPI_VOP_BIG);
	rockpi_vop_restore(&state, &fake_io, &fake);
	expect(fake.log_count == 0, "restore without apply must not access hardware");
}

int main(void)
{
	test_dsi0_start_programs_proven_780mbps_sequence();
	test_dsi0_lock_timeout_unwinds_reset_and_clocks();
	test_dsi0_each_setup_failure_unwinds_completed_steps();
	test_vopb_route_accesses_only_vopb();
	test_vopl_route_accesses_only_vopl();
	test_route_failure_accesses_neither_vop();
	test_vop_apply_sets_lane_and_bg_rb_only();
	test_vop_restore_preserves_unrelated_live_changes();
	test_vop_apply_is_idempotent();
	test_vop_restore_without_apply_is_noop();
	puts("PASS: RK3399 display compatibility core");
	return 0;
}
