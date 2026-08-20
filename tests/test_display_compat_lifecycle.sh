#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
provider=src/display_compat_main.c
header=src/display_compat.h

fail()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

function_body()
{
	function_name=$1
	awk -v function_name="$function_name" '
		$0 ~ "^(static )?.*[ *]" function_name "\\(" { found = 1 }
		found {
			print
			line = $0
			opens = gsub(/\{/, "{", line)
			line = $0
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
			if (opens)
				started = 1
			if (started && depth == 0)
				exit
		}
		END {
			if (!found || !started || depth != 0)
				exit 1
		}
	' "$provider"
}

body_line()
{
	pattern=$1
	awk -v pattern="$pattern" '
		index($0, pattern) {
			print NR
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	'
}

test -f "$provider" || fail 'missing RK3399 display compatibility provider'
test -f "$header" || fail 'missing display compatibility provider API header'

grep -Fq '.compatible = "rockpi,rk3399-dsi1-rpi-touchscreen-compat"' "$provider" ||
	fail 'provider must bind only the Rock Pi 4B+ touchscreen compatibility node'
for property in rockchip,dsi0 rockchip,dsi1 rockchip,grf rockchip,vopb rockchip,vopl; do
	grep -Fq "\"$property\"" "$provider" ||
		fail "provider must resolve $property"
done
grep -Fq 'of_parse_phandle(dev->of_node, property, 0)' "$provider" ||
	fail 'provider must resolve explicit hardware phandles with of_parse_phandle'
grep -Fq 'of_address_to_resource(node, 0, &resource)' "$provider" ||
	fail 'provider must validate MMIO resources before mapping'
grep -Fq 'of_iomap(node, 0)' "$provider" ||
	fail 'provider must map validated DT resources with of_iomap'
grep -Fq 'of_reset_control_get_exclusive_by_index(ctx->dsi0_node, 0)' "$provider" ||
	fail 'provider must exclusively own the disabled DSI0 reset'
grep -Fq '#include <linux/pm_runtime.h>' "$provider" ||
	fail 'provider must use the runtime-PM API for its VIO power-domain vote'
for clock in ref pclk phy_cfg grf; do
	grep -Fq "= \"$clock\"," "$provider" ||
		fail "provider must name the DSI0 $clock clock"
done
grep -Fq 'of_clk_get_by_name(ctx->dsi0_node, name)' "$provider" ||
	fail 'provider must acquire each DSI0 clock by name'

power_get_body=$(function_body rockpi_vio_power_get) ||
	fail 'provider is missing the VIO runtime-PM acquisition helper'
printf '%s\n' "$power_get_body" |
	grep -Fq 'pm_runtime_resume_and_get(ctx->dev)' ||
	fail 'provider must synchronously power VIO before acquiring its lifetime vote'
power_put_body=$(function_body rockpi_vio_power_put) ||
	fail 'provider is missing the normal VIO runtime-PM release helper'
printf '%s\n' "$power_put_body" |
	grep -Fq 'pm_runtime_put_sync_suspend(ctx->dev)' ||
	fail 'normal VIO release must synchronously drop the provider runtime-PM vote'
power_put_noidle_body=$(function_body rockpi_vio_power_put_noidle) ||
	fail 'provider is missing the system-PM VIO vote release helper'
printf '%s\n' "$power_put_noidle_body" |
	grep -Fq 'pm_runtime_put_noidle(ctx->dev)' ||
	fail 'system-PM VIO release must balance the vote without a nested runtime transition'

for callback in rockpi_write_dsi0_grf rockpi_read_dsi0 rockpi_write_dsi0; do
	callback_body=$(function_body "$callback")
	printf '%s\n' "$callback_body" | grep -Fq 'ctx->vio_power_held' ||
		fail "$callback must reject access without the VIO runtime-PM vote"
done

probe_body=$(function_body rockpi_display_compat_probe)
printf '%s\n' "$probe_body" |
	grep -Fq 'of_machine_is_compatible("radxa,rockpi4b-plus")' ||
	fail 'provider must reject every machine except the Rock Pi 4B+'
probe_pm_enable=$(printf '%s\n' "$probe_body" |
	body_line 'pm_runtime_enable(dev)') ||
	fail 'provider probe must enable runtime PM after platform genpd attachment'
probe_domain_check=$(printf '%s\n' "$probe_body" |
	body_line 'if (!dev->pm_domain)') ||
	fail 'provider probe must fail closed unless the platform bus attached VIO genpd'
probe_power_get=$(printf '%s\n' "$probe_body" |
	body_line 'rockpi_vio_power_get(ctx)') ||
	fail 'provider probe must acquire and hold the VIO power domain'
probe_start=$(printf '%s\n' "$probe_body" |
	body_line 'rockpi_dsi0_start(&ctx->dsi0_state, &rockpi_display_io, ctx)') ||
	fail 'provider probe must start and lock DSI0'
printf '%s\n' "$probe_body" |
	sed -n '/rockpi_dsi0_start(&ctx->dsi0_state, &rockpi_display_io, ctx)/,/device_link_add(ctx->dsi1, dev, DL_FLAG_STATELESS)/p' |
	grep -Fq 'if (ret)' || fail 'provider probe must check DSI0 start failure'
probe_link=$(printf '%s\n' "$probe_body" |
	body_line 'device_link_add(ctx->dsi1, dev, DL_FLAG_STATELESS)') ||
	fail 'provider must link DSI1 as consumer to the compatibility supplier'
probe_publish=$(printf '%s\n' "$probe_body" |
	body_line 'platform_set_drvdata(pdev, ctx)') ||
	fail 'provider must publish driver data after initialization'
[ "$probe_domain_check" -lt "$probe_pm_enable" ] &&
	[ "$probe_pm_enable" -lt "$probe_power_get" ] &&
	[ "$probe_power_get" -lt "$probe_start" ] &&
	[ "$probe_start" -lt "$probe_link" ] &&
	[ "$probe_link" -lt "$probe_publish" ] ||
	fail 'provider publication must follow VIO acquisition, DSI0 lock, and DSI1 link creation'
printf '%s\n' "$probe_body" |
	grep -Fq 'rockpi_vio_power_put(ctx)' ||
	fail 'provider probe failure must release an acquired VIO vote'
printf '%s\n' "$probe_body" |
	grep -Fq 'pm_runtime_disable(dev)' ||
	fail 'provider probe failure must disable runtime PM after balancing its vote'
if printf '%s\n' "$probe_body" | grep -Eq '\b(readl|writel)\('; then
	fail 'provider probe must not access either VOP'
fi

get_body=$(function_body rockpi_display_compat_get)
printf '%s\n' "$get_body" | grep -Fq 'of_parse_phandle(consumer->of_node, "rockpi,display-compat", 0)' ||
	fail 'panel consumer must resolve its explicit compatibility provider'
printf '%s\n' "$get_body" | grep -Fq 'return ERR_PTR(-EPROBE_DEFER);' ||
	fail 'consumer acquisition must defer until provider data is published'
printf '%s\n' "$get_body" | grep -Fq 'device_link_add(consumer, compat->dev,' &&
	printf '%s\n' "$get_body" | grep -Fq 'DL_FLAG_AUTOREMOVE_CONSUMER' ||
	fail 'consumer acquisition must add an auto-removing supplier link'

apply_body=$(function_body rockpi_display_compat_apply)
apply_lock=$(printf '%s\n' "$apply_body" | body_line 'mutex_lock(&compat->lock)') ||
	fail 'compatibility apply must serialize provider state'
apply_core=$(printf '%s\n' "$apply_body" |
	body_line 'rockpi_vop_apply(&compat->vop_state, &rockpi_display_io, compat)') ||
	fail 'compatibility apply must delegate sequencing to the tested core'
apply_unlock=$(printf '%s\n' "$apply_body" | body_line 'mutex_unlock(&compat->lock)') ||
	fail 'compatibility apply must release provider serialization'
[ "$apply_lock" -lt "$apply_core" ] && [ "$apply_core" -lt "$apply_unlock" ] ||
	fail 'compatibility apply must hold the mutex around the core operation'

route_body=$(function_body rockpi_resolve_dsi1_vop)
route_read=$(printf '%s\n' "$route_body" |
	body_line 'regmap_read(ctx->grf, RK3399_GRF_SOC_CON20, &soc_con20)') ||
	fail 'VOP selection must read the live DSI1 route from GRF SOC_CON20'
route_select=$(printf '%s\n' "$route_body" |
	body_line 'soc_con20 & RK3399_DSI1_LCDC_SEL') ||
	fail 'VOP selection must use only the DSI1 LCD-select bit'
[ "$route_read" -lt "$route_select" ] ||
	fail 'a GRF read error must return before selecting or accessing a VOP'
printf '%s\n' "$route_body" |
	grep -Fq 'ROCKPI_VOP_LIT : ROCKPI_VOP_BIG;' ||
	fail 'DSI1 LCD-select zero must choose VOPB and one must choose VOPL'

vop_base_body=$(function_body rockpi_vop_base)
printf '%s\n' "$vop_base_body" | grep -Fq 'if (vop == ROCKPI_VOP_BIG)' &&
	printf '%s\n' "$vop_base_body" | grep -Fq 'return ctx->vopb_base;' &&
	printf '%s\n' "$vop_base_body" | grep -Fq 'if (vop == ROCKPI_VOP_LIT)' &&
	printf '%s\n' "$vop_base_body" | grep -Fq 'return ctx->vopl_base;' ||
	fail 'VOP callbacks must resolve only the selected VOP mapping'
read_vop_body=$(function_body rockpi_read_vop)
write_vop_body=$(function_body rockpi_write_vop)
printf '%s\n' "$read_vop_body" | grep -Fq '*value = readl(base + offset);' &&
	printf '%s\n' "$write_vop_body" | grep -Fq 'writel(value, base + offset);' ||
	fail 'VOP callbacks must access only the single selected base'

suspend_body=$(function_body rockpi_display_compat_suspend)
suspend_restore=$(printf '%s\n' "$suspend_body" |
	body_line 'rockpi_vop_restore(&ctx->vop_state, &rockpi_display_io, ctx)') ||
	fail 'provider suspend must restore VOP state'
suspend_check=$(printf '%s\n' "$suspend_body" |
	body_line 'if (ctx->vop_state.applied)') ||
	fail 'provider suspend must reject an incomplete VOP restore'
suspend_stop=$(printf '%s\n' "$suspend_body" |
	body_line 'rockpi_dsi0_stop(&ctx->dsi0_state, &rockpi_display_io, ctx)') ||
	fail 'provider suspend must stop DSI0'
suspend_power_put=$(printf '%s\n' "$suspend_body" |
	body_line 'rockpi_vio_power_put_noidle(ctx)') ||
	fail 'provider suspend must release the VIO vote for genpd system sleep'
[ "$suspend_restore" -lt "$suspend_check" ] &&
	[ "$suspend_check" -lt "$suspend_stop" ] &&
	[ "$suspend_stop" -lt "$suspend_power_put" ] ||
	fail 'provider suspend must restore VOP and stop DSI0 before releasing VIO'

resume_body=$(function_body rockpi_display_compat_resume)
resume_power_get=$(printf '%s\n' "$resume_body" |
	body_line 'rockpi_vio_power_get(ctx)') ||
	fail 'provider resume must reacquire VIO before DSI0 restart'
resume_start=$(printf '%s\n' "$resume_body" |
	body_line 'rockpi_dsi0_start(&ctx->dsi0_state, &rockpi_display_io, ctx)') ||
	fail 'provider resume must restart DSI0'
[ "$resume_power_get" -lt "$resume_start" ] ||
	fail 'provider resume must hold VIO before accessing DSI0'
printf '%s\n' "$resume_body" | grep -Fq 'rockpi_vio_power_put_noidle(ctx)' &&
	printf '%s\n' "$resume_body" | grep -Fq 'return ret;' ||
	fail 'provider resume failure must release VIO and propagate the restart error'

remove_body=$(function_body rockpi_display_compat_remove)
remove_link=$(printf '%s\n' "$remove_body" |
	body_line 'device_link_del(ctx->dsi1_link)') ||
	fail 'provider remove must destroy the stateless DSI1 link'
remove_put=$(printf '%s\n' "$remove_body" |
	body_line 'put_device(ctx->dsi1)') ||
	fail 'provider remove must release the retained DSI1 reference'
remove_stop=$(printf '%s\n' "$remove_body" |
	body_line 'rockpi_dsi0_stop(&ctx->dsi0_state, &rockpi_display_io, ctx)') ||
	fail 'provider remove must stop DSI0'
remove_power_put=$(printf '%s\n' "$remove_body" |
	body_line 'rockpi_vio_power_put(ctx)') ||
	fail 'provider remove must release its VIO runtime-PM vote'
remove_pm_disable=$(printf '%s\n' "$remove_body" |
	body_line 'pm_runtime_disable(ctx->dev)') ||
	fail 'provider remove must disable runtime PM after dropping its vote'
[ "$remove_link" -lt "$remove_put" ] && [ "$remove_put" -lt "$remove_stop" ] &&
	[ "$remove_stop" -lt "$remove_power_put" ] &&
	[ "$remove_power_put" -lt "$remove_pm_disable" ] ||
	fail 'provider remove must unwind DSI1, stop DSI0, release VIO, then disable runtime PM'
if printf '%s\n' "$remove_body" | grep -Fq 'rockpi_vop_restore('; then
	fail 'provider remove must not access a possibly inactive VOP'
fi

for symbol in get put apply restore; do
	grep -Fq "EXPORT_SYMBOL_GPL(rockpi_display_compat_$symbol);" "$provider" ||
		fail "provider must GPL-export rockpi_display_compat_$symbol"
done
grep -Fq 'module_platform_driver(rockpi_display_compat_driver);' "$provider" ||
	fail 'provider must register as a platform driver'
grep -Fq '.pm = pm_sleep_ptr(&rockpi_display_compat_pm_ops),' "$provider" ||
	fail 'provider must register system sleep ordering callbacks'
grep -Fq 'obj-m += rockpi_rk3399_display_compat.o' Makefile ||
	fail 'Makefile must build the compatibility provider module'
grep -Fq 'rockpi_rk3399_display_compat-y := src/display_compat_main.o src/display_compat_core.o' Makefile ||
	fail 'provider module must link the tested portable compatibility core'

printf 'PASS: RK3399 display compatibility provider lifecycle\n'
