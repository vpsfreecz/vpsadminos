VERSION := $(shell date +%Y%m%d%H%M%S)
NAME := undefined

migration:
	@mkdir "migrations/$(VERSION)-$(NAME)"
	@cp -rp migrations/.template/* "migrations/$(VERSION)-$(NAME)"
	@echo "migrations/$(VERSION)-$(NAME)"

.PHONY: migration
