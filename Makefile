BUILD_ID := $(shell date +%Y%m%d%H%M%S)
VERSION := $(shell cat .version)
RELEASE_DATE := $(shell date +%Y-%m-%d)

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

svctl:
	./tools/update_gem.sh os/packages tools/svctl $(BUILD_ID)

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
	@sed -ri "s/ VERSION = '[^']+'/ VERSION = '$(VERSION)'/" tools/svctl/lib/svctl/version.rb

	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/[0-9]+\.[0-9]+\.[0-9]+$\/$(VERSION)/' tools/svctl/man/man8/svctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osctl/man/man8/osctl.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' osup/man/man8/osup.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' converter/man/man8/vpsadminos-convert.8.md
	@sed -ri '1!b;s/ [0-9]{4}-[0-9]{1,2}-[0-9]{1,2} / $(RELEASE_DATE) /' tools/svctl/man/man8/svctl.8.md

migration:
	$(MAKE) -C osup migration

.PHONY: build converter doc doc_serve qemu gems libosctl osctl osctld osctl-repo osup osctl-env-exec
.PHONY: version migration
