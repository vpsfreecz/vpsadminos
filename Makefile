BUILD_ID := $(shell date +%Y%m%d%H%M%S)

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

gems: libosctl osctl-repo osctl osctld converter

libosctl:
	./tools/update_gem.sh _nopkg libosctl $(BUILD_ID)

osctl:
	./tools/update_gem.sh os/packages osctl $(BUILD_ID)

osctld:
	./tools/update_gem.sh os/packages osctld $(BUILD_ID)

osctl-repo:
	./tools/update_gem.sh _nopkg osctl-repo $(BUILD_ID)

converter:
	./tools/update_gem.sh _nopkg converter $(BUILD_ID)

osctl-env-exec:
	./tools/update_gem.sh os/packages tools/osctl-env-exec $(BUILD_ID)

doc:
	mkdocs build

doc_serve:
	mkdocs serve

.PHONY: build converter doc doc_serve qemu gems libosctl osctl osctld osctl-repo osctl-env-exec
