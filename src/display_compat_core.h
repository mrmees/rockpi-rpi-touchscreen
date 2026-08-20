/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKPI_DISPLAY_COMPAT_CORE_H
#define ROCKPI_DISPLAY_COMPAT_CORE_H

#ifdef __KERNEL__
#include <linux/stddef.h>
#include <linux/types.h>
typedef u32 rockpi_u32;
#else
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t rockpi_u32;
#endif

#define ROCKPI_BIT(bit) (1U << (bit))

enum rockpi_vop_id {
	ROCKPI_VOP_BIG,
	ROCKPI_VOP_LIT,
};

struct rockpi_dsi0_state {
	bool clocks_enabled;
	bool reset_deasserted;
	bool started;
};

struct rockpi_vop_state {
	bool applied;
	enum rockpi_vop_id selected;
	bool original_data01_swap;
	rockpi_u32 original_rgb_swap;
};

struct rockpi_display_io {
	int (*enable_clocks)(void *context);
	void (*disable_clocks)(void *context);
	int (*assert_reset)(void *context);
	int (*deassert_reset)(void *context);
	int (*write_dsi0_grf)(void *context, rockpi_u32 offset,
			      rockpi_u32 value);
	int (*read_dsi0)(void *context, rockpi_u32 offset, rockpi_u32 *value);
	int (*write_dsi0)(void *context, rockpi_u32 offset, rockpi_u32 value);
	void (*delay_us)(void *context, rockpi_u32 min, rockpi_u32 max);
	void (*delay_ms)(void *context, rockpi_u32 delay);
	int (*resolve_dsi1_vop)(void *context, enum rockpi_vop_id *vop);
	int (*read_vop)(void *context, enum rockpi_vop_id vop,
			rockpi_u32 offset, rockpi_u32 *value);
	int (*write_vop)(void *context, enum rockpi_vop_id vop,
			 rockpi_u32 offset, rockpi_u32 value);
};

#define ROCKPI_DSI_PHY_RSTZ		0x00a0
#define ROCKPI_DSI_PHY_IF_CFG		0x00a4
#define ROCKPI_DSI_PHY_STATUS		0x00b0
#define ROCKPI_DSI_PHY_TST_CTRL0	0x00b4
#define ROCKPI_DSI_PHY_TST_CTRL1	0x00b8
#define ROCKPI_DSI0_GRF_SOC_CON22	0x6258

#define ROCKPI_VOP_CFG_DONE		0x0000
#define ROCKPI_VOP_SYS_CTRL		0x0008
#define ROCKPI_VOP_DSP_CTRL0		0x0010
#define ROCKPI_VOP_DATA01_SWAP		ROCKPI_BIT(17)
#define ROCKPI_VOP_RGB_SWAP_MASK	(7U << 12)
#define ROCKPI_VOP_RGB_SWAP_RB		(3U << 12)

int rockpi_dsi0_start(struct rockpi_dsi0_state *state,
		      const struct rockpi_display_io *io, void *context);
void rockpi_dsi0_stop(struct rockpi_dsi0_state *state,
		      const struct rockpi_display_io *io, void *context);
int rockpi_vop_apply(struct rockpi_vop_state *state,
		     const struct rockpi_display_io *io, void *context);
void rockpi_vop_restore(struct rockpi_vop_state *state,
			const struct rockpi_display_io *io, void *context);

#endif /* ROCKPI_DISPLAY_COMPAT_CORE_H */
