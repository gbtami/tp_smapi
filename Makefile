ifndef TP_MODULES
# This part runs as a normal, top-level Makefile:

KVER        := $(shell uname -r)
KSRC        := /lib/modules/$(KVER)/build
MOD_DIR     := /lib/modules/$(KVER)/kernel
PWD         := $(shell pwd)
IDIR        := include/linux
TP_DIR      := drivers/firmware
TP_MODULES  := tp_base.o tp_smapi.o 
SHELL       := /bin/bash

ifeq ($(HDAPS),1)
TP_MODULES  += hdaps.o
LOAD_HDAPS  := insmod ./hdaps.ko
else
LOAD_HDAPS  := :
endif

DEBUG := 0

ifneq ($(shell [ -f $(KSRC)/include/linux/platform_device.h ] && echo 1),1)
	$(error This driver requires kernel 2.6.15 or newer.)
endif

.PHONY: default clean modules load unload install patch check_hdaps mk-hdaps.diff
export TP_MODULES

#####################################################################
# Main targets

default: modules

# Build the modules tp_base.ko, tp_smapi.ko and (if HDAPS=1) hdaps.ko
modules: $(KSRC) $(patsubst %.o,%.c,$(TP_MODULES))
	$(MAKE) -C $(KSRC) M=$(PWD) modules

clean:
	rm -f tp_smapi.mod.* tp_smapi.o tp_smapi.ko .tp_smapi.*.cmd
	rm -f tp_base.mod.* tp_base.o tp_base.ko .tp_base.*.cmd
	rm -f hdaps.mod.* hdaps.o hdaps.ko .hdaps.*.cmd
	rm -f *~ diff/*~ *.orig diff/*.orig *.rej diff/*.rej
	rm -f tp_smapi-*-for-*.patch 
	rm -fr .tmp_versions Modules.symvers diff/hdaps.diff.tmp
	@if [ -f hdaps.c -a hdaps.c.flag -ot hdaps.c ]; then \
		echo 'WARNING: hdaps.c has changed since autogeneration, will not delete.'; \
	else \
		rm -f hdaps.c hdaps.c.flag; \
	fi

load: check_hdaps unload modules
	{ insmod ./tp_base.ko debug=$(DEBUG) &&\
	  insmod ./tp_smapi.ko debug=$(DEBUG) &&\
	  $(LOAD_HDAPS); }; :
	@echo -e '\nRecent dmesg output:' ; dmesg | tail -8

unload:
	if lsmod | grep -q '^hdaps '; then rmmod hdaps; fi
	if lsmod | grep -q '^tp_smapi '; then rmmod tp_smapi; fi
	if lsmod | grep -q '^tp_base '; then rmmod tp_base; fi

check_hdaps:
ifneq ($(HDAPS),1)
	@if lsmod | grep -q '^hdaps '; then \
	echo 'The hdaps driver is loaded. Use "make HDAPS=1 ..." to'\
	'patch hdaps for compatibility with tp_smapi.'\
	'This requires a kernel source tree.'; exit 1; fi
endif

install: modules
	rm -f $(MOD_DIR)/$(TP_DIR)/{tp_base,tp_smapi}.ko
ifeq ($(HDAPS),1)
	rm -f $(MOD_DIR)/drivers/hwmon/hdaps.ko
endif
	$(MAKE) -C $(KSRC) M=$(PWD) modules_install
	depmod -a

# Match hdaps.c from kernel tree into local copy.
# (First do a small change in our own patch if kernel != 2.6.17.x)
hdaps.c: $(KSRC)/drivers/hwmon/hdaps.c diff/hdaps.diff
	cat $(PWD)/diff/hdaps.diff \
	| if ! grep -q 'ret = -ENODEV' $(KSRC)/drivers/hwmon/hdaps.c; then \
	  perl -0777 -pe 's/(laptop not found.*\n.*)ENODEV/$$1ENXIO/'; else cat; fi \
	| if grep -q 'Celsius' $(KSRC)/drivers/hwmon/hdaps.c; then \
	  perl -0777 -pe 's/ celcius / Celsius /'; else cat; fi \
	| patch -d $(KSRC) -p1 -o $(PWD)/hdaps.c  ||  { rm -v hdaps.c; exit 1; }
	@touch -r hdaps.c hdaps.c.flag


#####################################################################
# Generate a stand-alone kernel patch

TP_VER := ${shell sed -ne 's/^\#define TP_VERSION \"\(.*\)\"/\1/gp' tp_smapi.c}
ORG    := linux-$(KVER)-orig
NEW    := linux-$(KVER)-patched
PATCH  := tp_smapi-$(TP_VER)-for-$(KVER).patch

BASE_IN_PATCH  := 1
SMAPI_IN_PATCH := 1

patch: hdaps.c
	TMPDIR=`mktemp -d /tmp/tp_smapi-patch.XXXXXX` &&\
	echo "Work directory: $$TMPDIR" &&\
	cd $$TMPDIR &&\
	mkdir -p $(ORG)/$(TP_DIR) &&\
	mkdir -p $(ORG)/$(IDIR) &&\
	mkdir -p $(ORG)/drivers/hwmon &&\
	cp $(KSRC)/$(TP_DIR)/{Kconfig,Makefile} $(ORG)/$(TP_DIR) &&\
	cp $(KSRC)/drivers/hwmon/{Kconfig,hdaps.c} $(ORG)/drivers/hwmon/ &&\
	cp -r $(ORG) $(NEW) &&\
	\
	if [ "$(BASE_IN_PATCH)" == 1 ]; then \
	patch --no-backup-if-mismatch -s -d $(NEW) -i $(PWD)/diff/Kconfig-tp_base.diff -p1 &&\
	cp $(PWD)/tp_base.c $(NEW)/$(TP_DIR)/tp_base.c &&\
	cp $(PWD)/tp_base.h $(NEW)/$(IDIR)/tp_base.h &&\
	cp $(PWD)/hdaps.c $(NEW)/drivers/hwmon/ &&\
	sed -i -e '$$aobj-$$(CONFIG_TP_BASE)           += tp_base.o' $(NEW)/$(TP_DIR)/Makefile \
	; fi &&\
	\
	if [ "$(SMAPI_IN_PATCH)" == 1 ]; then \
	sed -i -e '$$aobj-$$(CONFIG_TP_SMAPI)          += tp_smapi.o' $(NEW)/$(TP_DIR)/Makefile &&\
	cp $(PWD)/tp_smapi.c $(NEW)/$(TP_DIR)/tp_smapi.c &&\
	patch --no-backup-if-mismatch -s -d $(NEW)/$(TP_DIR) -i $(PWD)/diff/tp_smapi-no_cd.diff -p1 &&\
	patch --no-backup-if-mismatch -s -d $(NEW) -i $(PWD)/diff/Kconfig-tp_smapi.diff -p1 &&\
	mkdir -p $(NEW)/Documentation &&\
	perl -0777 -pe 's/\n(Installation\n---+|Conflict with HDAPS\n---+|Files in this package\n---+|Setting and getting CD-ROM speed:\n).*?\n(?=[^\n]*\n-----)/\n/gs' $(PWD)/README > $(NEW)/Documentation/tp_smapi.txt \
	; fi &&\
	\
	{ diff -dNurp $(ORG) $(NEW) > patch \
	  || [ $$? -lt 2 ]; } &&\
	{ diffstat patch; echo; echo; cat patch; } \
	  > $(PWD)/${PATCH} &&\
	rm -r $$TMPDIR
	@echo -e "\nPatch file created:\n  ${PATCH}"
	@echo -e "To apply, use:\n  patch -p1 -d ${KSRC} < ${PATCH}"

#####################################################################
# Tools for preparing a release. Ignore these.

mk-hdaps.diff: diff/hdaps.diff $(KSRC)/drivers/hwmon/hdaps.c
	{ head -2 diff/hdaps.diff; diff -up -U3 $(KSRC)/drivers/hwmon/hdaps.c hdaps.c | tail -n +3; } > diff/hdaps.diff.tmp || :
	mv diff/hdaps.diff.tmp diff/hdaps.diff

else
#####################################################################
# This part runs as a submake in kernel Makefile context:

CFLAGS := $(CFLAGS) -I$(M)/include
obj-m  := $(TP_MODULES)

endif
