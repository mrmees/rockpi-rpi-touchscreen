// SPDX-License-Identifier: GPL-2.0-only
/*
 * RK3399 compatibility state provider for the original Raspberry Pi
 * 800x480 touchscreen on the Rock Pi 4B+.
 */

#include <linux/bitops.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/pm_runtime.h>
#include <linux/regmap.h>
#include <linux/reset.h>

#include "display_compat.h"
#include "display_compat_core.h"

#define RK3399_GRF_SOC_CON20		0x6250
#define RK3399_DSI1_LCDC_SEL		BIT(4)

enum rockpi_dsi0_clock_id {
	ROCKPI_DSI0_CLK_REF,
	ROCKPI_DSI0_CLK_PCLK,
	ROCKPI_DSI0_CLK_PHY_CFG,
	ROCKPI_DSI0_CLK_GRF,
	ROCKPI_DSI0_CLK_COUNT,
};

struct rockpi_display_compat {
	struct device *dev;
	struct rockpi_dsi0_state dsi0_state;
	struct rockpi_vop_state vop_state;
	struct clk_bulk_data dsi0_clocks[ROCKPI_DSI0_CLK_COUNT];
	struct reset_control *dsi0_reset;
	struct regmap *grf;
	void __iomem *dsi0_base;
	void __iomem *vopb_base;
	void __iomem *vopl_base;
	struct device_node *dsi0_node;
	struct device *dsi1;
	struct device_link *dsi1_link;
	bool vio_power_held;
	struct mutex lock; /* Serializes DSI0 and saved VOP state. */
};

static void rockpi_put_node(void *data)
{
	of_node_put(data);
}

static void rockpi_unmap(void *data)
{
	iounmap(data);
}

static void rockpi_put_clock(void *data)
{
	clk_put(data);
}

static void rockpi_put_reset(void *data)
{
	reset_control_put(data);
}

static int rockpi_vio_power_get(struct rockpi_display_compat *ctx)
{
	int ret;

	if (WARN_ON(ctx->vio_power_held))
		return -EBUSY;

	ret = pm_runtime_resume_and_get(ctx->dev);
	if (ret)
		return ret;

	ctx->vio_power_held = true;
	return 0;
}

static void rockpi_vio_power_put(struct rockpi_display_compat *ctx)
{
	int ret;

	if (!ctx->vio_power_held)
		return;

	ctx->vio_power_held = false;
	ret = pm_runtime_put_sync_suspend(ctx->dev);
	if (ret < 0)
		dev_warn(ctx->dev, "failed to runtime-suspend VIO: %d\n", ret);
}

static void rockpi_vio_power_put_noidle(struct rockpi_display_compat *ctx)
{
	if (!ctx->vio_power_held)
		return;

	ctx->vio_power_held = false;
	pm_runtime_put_noidle(ctx->dev);
}

static struct device_node *
rockpi_get_node(struct device *dev, const char *property)
{
	struct device_node *node;
	int ret;

	node = of_parse_phandle(dev->of_node, property, 0);
	if (!node)
		return ERR_PTR(-EINVAL);

	ret = devm_add_action_or_reset(dev, rockpi_put_node, node);
	if (ret)
		return ERR_PTR(ret);

	return node;
}

static void __iomem *rockpi_map_node(struct device *dev,
				     struct device_node *node)
{
	struct resource resource;
	void __iomem *base;
	int ret;

	ret = of_address_to_resource(node, 0, &resource);
	if (ret)
		return ERR_PTR(ret);

	base = of_iomap(node, 0);
	if (!base)
		return ERR_PTR(-ENOMEM);

	ret = devm_add_action_or_reset(dev, rockpi_unmap, base);
	if (ret)
		return ERR_PTR(ret);

	return base;
}

static int rockpi_get_clock(struct rockpi_display_compat *ctx,
			    enum rockpi_dsi0_clock_id id, const char *name)
{
	struct clk *clock;
	int ret;

	clock = of_clk_get_by_name(ctx->dsi0_node, name);
	if (IS_ERR(clock))
		return PTR_ERR(clock);

	ret = devm_add_action_or_reset(ctx->dev, rockpi_put_clock, clock);
	if (ret)
		return ret;

	ctx->dsi0_clocks[id].id = name;
	ctx->dsi0_clocks[id].clk = clock;
	return 0;
}

static int rockpi_enable_clocks(void *context)
{
	struct rockpi_display_compat *ctx = context;

	return clk_bulk_prepare_enable(ROCKPI_DSI0_CLK_COUNT,
				       ctx->dsi0_clocks);
}

static void rockpi_disable_clocks(void *context)
{
	struct rockpi_display_compat *ctx = context;

	clk_bulk_disable_unprepare(ROCKPI_DSI0_CLK_COUNT, ctx->dsi0_clocks);
}

static int rockpi_assert_reset(void *context)
{
	struct rockpi_display_compat *ctx = context;

	return reset_control_assert(ctx->dsi0_reset);
}

static int rockpi_deassert_reset(void *context)
{
	struct rockpi_display_compat *ctx = context;

	return reset_control_deassert(ctx->dsi0_reset);
}

static int rockpi_write_dsi0_grf(void *context, rockpi_u32 offset,
				 rockpi_u32 value)
{
	struct rockpi_display_compat *ctx = context;

	if (WARN_ON(!ctx->vio_power_held))
		return -EIO;

	return regmap_write(ctx->grf, offset, value);
}

static int rockpi_read_dsi0(void *context, rockpi_u32 offset,
			    rockpi_u32 *value)
{
	struct rockpi_display_compat *ctx = context;

	if (WARN_ON(!ctx->vio_power_held))
		return -EIO;

	*value = readl(ctx->dsi0_base + offset);
	return 0;
}

static int rockpi_write_dsi0(void *context, rockpi_u32 offset,
			     rockpi_u32 value)
{
	struct rockpi_display_compat *ctx = context;

	if (WARN_ON(!ctx->vio_power_held))
		return -EIO;

	writel(value, ctx->dsi0_base + offset);
	return 0;
}

static void rockpi_delay_us(void *context, rockpi_u32 min, rockpi_u32 max)
{
	usleep_range(min, max);
}

static void rockpi_delay_ms(void *context, rockpi_u32 delay)
{
	usleep_range(delay * USEC_PER_MSEC, (delay + 1) * USEC_PER_MSEC);
}

static int rockpi_resolve_dsi1_vop(void *context, enum rockpi_vop_id *vop)
{
	struct rockpi_display_compat *ctx = context;
	unsigned int soc_con20;
	int ret;

	ret = regmap_read(ctx->grf, RK3399_GRF_SOC_CON20, &soc_con20);
	if (ret)
		return ret;

	*vop = soc_con20 & RK3399_DSI1_LCDC_SEL ?
		ROCKPI_VOP_LIT : ROCKPI_VOP_BIG;
	return 0;
}

static void __iomem *rockpi_vop_base(struct rockpi_display_compat *ctx,
				     enum rockpi_vop_id vop)
{
	if (vop == ROCKPI_VOP_BIG)
		return ctx->vopb_base;
	if (vop == ROCKPI_VOP_LIT)
		return ctx->vopl_base;
	return NULL;
}

static int rockpi_read_vop(void *context, enum rockpi_vop_id vop,
			   rockpi_u32 offset, rockpi_u32 *value)
{
	struct rockpi_display_compat *ctx = context;
	void __iomem *base = rockpi_vop_base(ctx, vop);

	if (!base)
		return -EINVAL;

	*value = readl(base + offset);
	return 0;
}

static int rockpi_write_vop(void *context, enum rockpi_vop_id vop,
			    rockpi_u32 offset, rockpi_u32 value)
{
	struct rockpi_display_compat *ctx = context;
	void __iomem *base = rockpi_vop_base(ctx, vop);

	if (!base)
		return -EINVAL;

	writel(value, base + offset);
	return 0;
}

static const struct rockpi_display_io rockpi_display_io = {
	.enable_clocks = rockpi_enable_clocks,
	.disable_clocks = rockpi_disable_clocks,
	.assert_reset = rockpi_assert_reset,
	.deassert_reset = rockpi_deassert_reset,
	.write_dsi0_grf = rockpi_write_dsi0_grf,
	.read_dsi0 = rockpi_read_dsi0,
	.write_dsi0 = rockpi_write_dsi0,
	.delay_us = rockpi_delay_us,
	.delay_ms = rockpi_delay_ms,
	.resolve_dsi1_vop = rockpi_resolve_dsi1_vop,
	.read_vop = rockpi_read_vop,
	.write_vop = rockpi_write_vop,
};

static int rockpi_display_compat_resources(struct platform_device *pdev,
					   struct rockpi_display_compat *ctx)
{
	static const char *const clock_names[ROCKPI_DSI0_CLK_COUNT] = {
		[ROCKPI_DSI0_CLK_REF] = "ref",
		[ROCKPI_DSI0_CLK_PCLK] = "pclk",
		[ROCKPI_DSI0_CLK_PHY_CFG] = "phy_cfg",
		[ROCKPI_DSI0_CLK_GRF] = "grf",
	};
	struct platform_device *dsi1_pdev;
	struct device_node *vopl_node;
	struct device_node *vopb_node;
	struct device_node *dsi1_node;
	struct device_node *grf_node;
	struct device *dev = &pdev->dev;
	int ret;
	int i;

	ctx->dsi0_node = rockpi_get_node(dev, "rockchip,dsi0");
	if (IS_ERR(ctx->dsi0_node))
		return PTR_ERR(ctx->dsi0_node);

	dsi1_node = rockpi_get_node(dev, "rockchip,dsi1");
	if (IS_ERR(dsi1_node))
		return PTR_ERR(dsi1_node);

	grf_node = rockpi_get_node(dev, "rockchip,grf");
	if (IS_ERR(grf_node))
		return PTR_ERR(grf_node);

	vopb_node = rockpi_get_node(dev, "rockchip,vopb");
	if (IS_ERR(vopb_node))
		return PTR_ERR(vopb_node);

	vopl_node = rockpi_get_node(dev, "rockchip,vopl");
	if (IS_ERR(vopl_node))
		return PTR_ERR(vopl_node);

	ctx->dsi0_base = rockpi_map_node(dev, ctx->dsi0_node);
	if (IS_ERR(ctx->dsi0_base))
		return PTR_ERR(ctx->dsi0_base);

	ctx->vopb_base = rockpi_map_node(dev, vopb_node);
	if (IS_ERR(ctx->vopb_base))
		return PTR_ERR(ctx->vopb_base);

	ctx->vopl_base = rockpi_map_node(dev, vopl_node);
	if (IS_ERR(ctx->vopl_base))
		return PTR_ERR(ctx->vopl_base);

	ctx->grf = syscon_node_to_regmap(grf_node);
	if (IS_ERR(ctx->grf))
		return PTR_ERR(ctx->grf);

	for (i = 0; i < ROCKPI_DSI0_CLK_COUNT; i++) {
		ret = rockpi_get_clock(ctx, i, clock_names[i]);
		if (ret)
			return ret;
	}

	ctx->dsi0_reset =
		of_reset_control_get_exclusive_by_index(ctx->dsi0_node, 0);
	if (IS_ERR(ctx->dsi0_reset))
		return PTR_ERR(ctx->dsi0_reset);

	ret = devm_add_action_or_reset(dev, rockpi_put_reset,
				       ctx->dsi0_reset);
	if (ret)
		return ret;

	dsi1_pdev = of_find_device_by_node(dsi1_node);
	if (!dsi1_pdev)
		return -EPROBE_DEFER;
	ctx->dsi1 = &dsi1_pdev->dev;

	return 0;
}

static int rockpi_display_compat_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct rockpi_display_compat *ctx;
	int ret;

	if (!of_machine_is_compatible("radxa,rockpi4b-plus"))
		return -ENODEV;

	ctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ctx->dev = dev;
	mutex_init(&ctx->lock);

	ret = rockpi_display_compat_resources(pdev, ctx);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to acquire compatibility resources\n");
	if (!dev->pm_domain) {
		ret = -ENODEV;
		goto put_dsi1;
	}

	pm_runtime_enable(dev);
	ret = rockpi_vio_power_get(ctx);
	if (ret)
		goto disable_runtime_pm;

	ret = rockpi_dsi0_start(&ctx->dsi0_state, &rockpi_display_io, ctx);
	if (ret)
		goto put_vio_power;

	ctx->dsi1_link = device_link_add(ctx->dsi1, dev, DL_FLAG_STATELESS);
	if (!ctx->dsi1_link) {
		ret = -ENOMEM;
		goto stop_dsi0;
	}

	platform_set_drvdata(pdev, ctx);
	dev_info(dev, "locked disabled DSI0 PHY compatibility supplier\n");
	return 0;

stop_dsi0:
	rockpi_dsi0_stop(&ctx->dsi0_state, &rockpi_display_io, ctx);
put_vio_power:
	rockpi_vio_power_put(ctx);
disable_runtime_pm:
	pm_runtime_disable(dev);
put_dsi1:
	put_device(ctx->dsi1);
	return dev_err_probe(dev, ret,
			     "failed to start compatibility provider\n");
}

static void rockpi_display_compat_remove(struct platform_device *pdev)
{
	struct rockpi_display_compat *ctx = platform_get_drvdata(pdev);

	device_link_del(ctx->dsi1_link);
	put_device(ctx->dsi1);
	mutex_lock(&ctx->lock);
	rockpi_dsi0_stop(&ctx->dsi0_state, &rockpi_display_io, ctx);
	rockpi_vio_power_put(ctx);
	mutex_unlock(&ctx->lock);
	pm_runtime_disable(ctx->dev);
}

struct rockpi_display_compat *rockpi_display_compat_get(struct device *consumer)
{
	struct rockpi_display_compat *compat;
	struct platform_device *provider;
	struct device_link *link;
	struct device_node *node;

	if (!consumer || !consumer->of_node)
		return ERR_PTR(-EINVAL);

	node = of_parse_phandle(consumer->of_node, "rockpi,display-compat", 0);
	if (!node)
		return ERR_PTR(-ENODEV);

	provider = of_find_device_by_node(node);
	of_node_put(node);
	if (!provider)
		return ERR_PTR(-EPROBE_DEFER);

	compat = platform_get_drvdata(provider);
	if (!compat) {
		put_device(&provider->dev);
		return ERR_PTR(-EPROBE_DEFER);
	}

	link = device_link_add(consumer, compat->dev,
			       DL_FLAG_AUTOREMOVE_CONSUMER);
	if (!link) {
		put_device(&provider->dev);
		return ERR_PTR(-ENOMEM);
	}

	return compat;
}
EXPORT_SYMBOL_GPL(rockpi_display_compat_get);

void rockpi_display_compat_put(struct rockpi_display_compat *compat)
{
	if (compat)
		put_device(compat->dev);
}
EXPORT_SYMBOL_GPL(rockpi_display_compat_put);

int rockpi_display_compat_apply(struct rockpi_display_compat *compat)
{
	int ret;

	if (!compat)
		return -EINVAL;

	mutex_lock(&compat->lock);
	ret = rockpi_vop_apply(&compat->vop_state, &rockpi_display_io, compat);
	mutex_unlock(&compat->lock);
	return ret;
}
EXPORT_SYMBOL_GPL(rockpi_display_compat_apply);

void rockpi_display_compat_restore(struct rockpi_display_compat *compat)
{
	if (!compat)
		return;

	mutex_lock(&compat->lock);
	rockpi_vop_restore(&compat->vop_state, &rockpi_display_io, compat);
	mutex_unlock(&compat->lock);
}
EXPORT_SYMBOL_GPL(rockpi_display_compat_restore);

static int rockpi_display_compat_suspend(struct device *dev)
{
	struct rockpi_display_compat *ctx = dev_get_drvdata(dev);

	mutex_lock(&ctx->lock);
	rockpi_vop_restore(&ctx->vop_state, &rockpi_display_io, ctx);
	if (ctx->vop_state.applied) {
		mutex_unlock(&ctx->lock);
		dev_err(dev, "refusing suspend with compatibility still applied\n");
		return -EIO;
	}
	rockpi_dsi0_stop(&ctx->dsi0_state, &rockpi_display_io, ctx);
	rockpi_vio_power_put_noidle(ctx);
	mutex_unlock(&ctx->lock);
	return 0;
}

static int rockpi_display_compat_resume(struct device *dev)
{
	struct rockpi_display_compat *ctx = dev_get_drvdata(dev);
	int ret;

	mutex_lock(&ctx->lock);
	ret = rockpi_vio_power_get(ctx);
	if (ret)
		goto unlock;
	ret = rockpi_dsi0_start(&ctx->dsi0_state, &rockpi_display_io, ctx);
	if (ret)
		rockpi_vio_power_put_noidle(ctx);
unlock:
	mutex_unlock(&ctx->lock);
	return ret;
}

static DEFINE_SIMPLE_DEV_PM_OPS(rockpi_display_compat_pm_ops,
				rockpi_display_compat_suspend,
				rockpi_display_compat_resume);

static const struct of_device_id rockpi_display_compat_of_match[] = {
	{ .compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat" },
	{ }
};
MODULE_DEVICE_TABLE(of, rockpi_display_compat_of_match);

static struct platform_driver rockpi_display_compat_driver = {
	.probe = rockpi_display_compat_probe,
	.remove = rockpi_display_compat_remove,
	.driver = {
		.name = "rockpi_rk3399_display_compat",
		.of_match_table = rockpi_display_compat_of_match,
		.pm = pm_sleep_ptr(&rockpi_display_compat_pm_ops),
	},
};
module_platform_driver(rockpi_display_compat_driver);

MODULE_AUTHOR("Rock Pi RPi Touchscreen contributors");
MODULE_DESCRIPTION("RK3399 DSI1 Raspberry Pi touchscreen compatibility provider");
MODULE_LICENSE("GPL v2");
