BUILD_ID := $(shell date +%Y%m%d%H%M%S)

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

gems: libosctl osctl osctld

libosctl:
	./tools/update_gem.sh _nopkg libosctl $(BUILD_ID)

osctl:
	./tools/update_gem.sh os/packages osctl $(BUILD_ID)

osctld:
	./tools/update_gem.sh os/packages osctld $(BUILD_ID)

doc:
	mkdocs build

doc_serve:
	mkdocs serve

.PHONY: build doc doc_serve qemu gems libosctl osctl osctld
