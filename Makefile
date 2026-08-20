ifneq ($(KERNELRELEASE),)
obj-m += raspits_ft5426.o
raspits_ft5426-y := src/raspits_ft5426.o
obj-m += panel_rockpi_rpi_touchscreen.o
panel_rockpi_rpi_touchscreen-y := src/panel_rockpi_rpi_touchscreen.o
obj-m += rockpi_rk3399_display_compat.o
rockpi_rk3399_display_compat-y := src/display_compat_main.o src/display_compat_core.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

.PHONY: all modules clean test

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

test:
	cc -std=c11 -Wall -Wextra -Werror -I. tests/test_protocol.c -o /tmp/test_ft5426
	/tmp/test_ft5426
	cc -std=c11 -Wall -Wextra -Werror -I. tests/test_display_compat.c src/display_compat_core.c -o /tmp/test_display_compat
	/tmp/test_display_compat
	sh tests/test_touch_mapper.sh
	sh tests/test_driver_lifecycle.sh
	sh tests/test_panel_lifecycle.sh
	sh tests/test_display_compat_lifecycle.sh
	sh tests/test_overlay.sh
	sh tests/test_scripts.sh
	sh tests/test_dkms.sh
	sh tests/test_validate.sh
	sh tests/test_docs.sh
endif
