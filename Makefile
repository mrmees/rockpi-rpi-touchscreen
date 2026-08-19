ifneq ($(KERNELRELEASE),)
obj-m += raspits_ft5426.o
raspits_ft5426-y := src/raspits_ft5426.o
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
	sh tests/test_overlay.sh
	sh tests/test_scripts.sh
	sh tests/test_dkms.sh
	sh tests/test_validate.sh
	sh tests/test_docs.sh
endif
