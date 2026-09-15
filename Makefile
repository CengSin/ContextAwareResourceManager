.PHONY: checks build app run

VERSION ?=
BUILD ?=
PKG_ARGS :=
ifneq ($(VERSION),)
PKG_ARGS += --version $(VERSION)
endif
ifneq ($(BUILD),)
PKG_ARGS += --build $(BUILD)
endif

checks:
	swift run StewardChecks

build:
	swift build --product ResourceSteward

app:
	./scripts/package-app.sh $(PKG_ARGS)

run: app
	open dist/ResourceSteward.app
