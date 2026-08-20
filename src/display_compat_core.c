/* SPDX-License-Identifier: GPL-2.0-only */
#ifdef __KERNEL__
#include <linux/errno.h>
#else
#include <errno.h>
#endif

#include "display_compat_core.h"

#define ROCKPI_BIT(bit) (1U << (bit))

static int rockpi_dsi0_phy_write(const struct rockpi_display_io *io,
				 void *context, rockpi_u32 code, rockpi_u32 value)
{
	int ret;

	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, ROCKPI_BIT(1));
	if (ret)
		return ret;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL1,
			     ROCKPI_BIT(16) | code);
	if (ret)
		return ret;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, 0);
	if (ret)
		return ret;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL1, value);
	if (ret)
		return ret;
	return io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, ROCKPI_BIT(1));
}

static bool rockpi_dsi0_io_valid(const struct rockpi_display_io *io)
{
	return io && io->enable_clocks && io->disable_clocks && io->assert_reset &&
		io->deassert_reset && io->write_dsi0_grf && io->read_dsi0 &&
		io->write_dsi0 && io->delay_us && io->delay_ms;
}

int rockpi_dsi0_start(struct rockpi_dsi0_state *state,
			      const struct rockpi_display_io *io, void *context)
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
	rockpi_u32 status;
	size_t i;
	int ret;

	if (!state || !rockpi_dsi0_io_valid(io))
		return -EINVAL;
	if (state->started)
		return 0;

	ret = io->enable_clocks(context);
	if (ret)
		goto unwind;
	state->clocks_enabled = true;
	ret = io->assert_reset(context);
	if (ret)
		goto unwind;
	io->delay_us(context, 10, 20);
	ret = io->deassert_reset(context);
	if (ret)
		goto unwind;
	state->reset_deasserted = true;
	ret = io->write_dsi0_grf(context, ROCKPI_DSI0_GRF_SOC_CON22, 0xffff0000);
	if (ret)
		goto unwind;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_RSTZ, 0);
	if (ret)
		goto unwind;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, 0);
	if (ret)
		goto unwind;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, ROCKPI_BIT(0));
	if (ret)
		goto unwind;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_TST_CTRL0, 0);
	if (ret)
		goto unwind;
	for (i = 0; i < sizeof(phy) / sizeof(phy[0]); i++) {
		ret = rockpi_dsi0_phy_write(io, context, phy[i][0], phy[i][1]);
		if (ret)
			goto unwind;
	}
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_IF_CFG, 0x2000);
	if (ret)
		goto unwind;
	ret = io->write_dsi0(context, ROCKPI_DSI_PHY_RSTZ,
			     ROCKPI_BIT(3) | ROCKPI_BIT(2) | ROCKPI_BIT(1) | ROCKPI_BIT(0));
	if (ret)
		goto unwind;
	for (i = 0; i < 10; i++) {
		ret = io->read_dsi0(context, ROCKPI_DSI_PHY_STATUS, &status);
		if (ret)
			goto unwind;
		if (status & ROCKPI_BIT(0)) {
			state->started = true;
			return 0;
		}
		if (i < 9)
			io->delay_ms(context, 1);
	}
	ret = -ETIMEDOUT;

unwind:
	rockpi_dsi0_stop(state, io, context);
	return ret;
}

void rockpi_dsi0_stop(struct rockpi_dsi0_state *state,
		      const struct rockpi_display_io *io, void *context)
{
	if (!state || !io)
		return;
	if (state->clocks_enabled && io->write_dsi0)
		(void)io->write_dsi0(context, ROCKPI_DSI_PHY_RSTZ, 0);
	if (state->reset_deasserted && io->assert_reset)
		(void)io->assert_reset(context);
	if (state->clocks_enabled && io->disable_clocks)
		io->disable_clocks(context);
	*state = (struct rockpi_dsi0_state) { 0 };
}

static bool rockpi_vop_io_valid(const struct rockpi_display_io *io)
{
	return io && io->resolve_dsi1_vop && io->read_vop && io->write_vop;
}

int rockpi_vop_apply(struct rockpi_vop_state *state,
		     const struct rockpi_display_io *io, void *context)
{
	enum rockpi_vop_id selected;
	rockpi_u32 sys_ctrl;
	rockpi_u32 dsp_ctrl0;
	int ret;

	if (!state || !rockpi_vop_io_valid(io))
		return -EINVAL;
	if (state->applied)
		return 0;
	ret = io->resolve_dsi1_vop(context, &selected);
	if (ret)
		return ret;
	ret = io->read_vop(context, selected, ROCKPI_VOP_SYS_CTRL, &sys_ctrl);
	if (ret)
		return ret;
	ret = io->read_vop(context, selected, ROCKPI_VOP_DSP_CTRL0, &dsp_ctrl0);
	if (ret)
		return ret;
	ret = io->write_vop(context, selected, ROCKPI_VOP_SYS_CTRL,
			    sys_ctrl | ROCKPI_VOP_DATA01_SWAP);
	if (ret)
		return ret;
	ret = io->write_vop(context, selected, ROCKPI_VOP_DSP_CTRL0,
			    (dsp_ctrl0 & ~ROCKPI_VOP_RGB_SWAP_MASK) |
			    ROCKPI_VOP_RGB_SWAP_RB);
	if (ret)
		return ret;
	ret = io->write_vop(context, selected, ROCKPI_VOP_CFG_DONE, 1);
	if (ret)
		return ret;
	state->selected = selected;
	state->original_data01_swap = !!(sys_ctrl & ROCKPI_VOP_DATA01_SWAP);
	state->original_rgb_swap = dsp_ctrl0 & ROCKPI_VOP_RGB_SWAP_MASK;
	state->applied = true;
	return 0;
}

void rockpi_vop_restore(struct rockpi_vop_state *state,
			const struct rockpi_display_io *io, void *context)
{
	rockpi_u32 sys_ctrl;
	rockpi_u32 dsp_ctrl0;
	rockpi_u32 restored_data01;
	int ret;

	if (!state || !state->applied || !rockpi_vop_io_valid(io))
		return;
	ret = io->read_vop(context, state->selected, ROCKPI_VOP_SYS_CTRL,
			   &sys_ctrl);
	if (ret)
		return;
	ret = io->read_vop(context, state->selected, ROCKPI_VOP_DSP_CTRL0,
			   &dsp_ctrl0);
	if (ret)
		return;
	restored_data01 = state->original_data01_swap ? ROCKPI_VOP_DATA01_SWAP : 0;
	ret = io->write_vop(context, state->selected, ROCKPI_VOP_SYS_CTRL,
			    (sys_ctrl & ~ROCKPI_VOP_DATA01_SWAP) | restored_data01);
	if (ret)
		return;
	ret = io->write_vop(context, state->selected, ROCKPI_VOP_DSP_CTRL0,
			    (dsp_ctrl0 & ~ROCKPI_VOP_RGB_SWAP_MASK) |
			    state->original_rgb_swap);
	if (ret)
		return;
	ret = io->write_vop(context, state->selected, ROCKPI_VOP_CFG_DONE, 1);
	if (ret)
		return;
	*state = (struct rockpi_vop_state) { 0 };
}
