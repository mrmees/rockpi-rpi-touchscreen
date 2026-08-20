/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ROCKPI_DISPLAY_COMPAT_H
#define ROCKPI_DISPLAY_COMPAT_H

struct device;
struct rockpi_display_compat;

struct rockpi_display_compat *rockpi_display_compat_get(struct device *consumer);
void rockpi_display_compat_put(struct rockpi_display_compat *compat);
int rockpi_display_compat_apply(struct rockpi_display_compat *compat);
void rockpi_display_compat_restore(struct rockpi_display_compat *compat);

#endif /* ROCKPI_DISPLAY_COMPAT_H */
