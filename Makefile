BUILD_ID := $(shell date +%Y%m%d%H%M%S)
VERSION := $(shell cat .version)

build:
	$(MAKE) -C os build

qemu:
	$(MAKE) -C os qemu

toplevel:
	$(MAKE) -C os toplevel

gems: libosctl osctl-repo osctl osctld osup converter
	echo "$(VERSION).build$(BUILD_ID)" > .build_id

libosctl:
	./tools/update_gem.sh _nopkg libosctl $(BUILD_ID)

osctl:
	./tools/update_gem.sh os/packages osctl $(BUILD_ID)

osctld:
	./tools/update_gem.sh os/packages osctld $(BUILD_ID)

osctl-repo:
	./tools/update_gem.sh _nopkg osctl-repo $(BUILD_ID)

osup:
	./tools/update_gem.sh os/packages osup $(BUILD_ID)

converter:
	./tools/update_gem.sh _nopkg converter $(BUILD_ID)

osctl-env-exec:
	./tools/update_gem.sh os/packages tools/osctl-env-exec $(BUILD_ID)

doc:
	mkdocs build

doc_serve:
	mkdocs serve

version:
	@echo "$(VERSION)" > .version
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctld/lib/osctld/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl/lib/osctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" libosctl/lib/libosctl/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" converter/lib/vpsadminos-converter/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osctl-repo/lib/osctl/repo/version.rb
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" osup/lib/osup/version.rb

migration:
	$(MAKE) -C osup migration

.PHONY: build converter doc doc_serve qemu gems libosctl osctl osctld osctl-repo osup osctl-env-exec
.PHONY: version migration
