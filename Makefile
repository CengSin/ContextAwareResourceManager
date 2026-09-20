COMMENT_CHECKER ?= $(HOME)/.agents/skills/swift-comment-checker/scripts/check-comments.sh

.PHONY: checks build app run clean-comments check-comments dev

VERSION ?=
BUILD ?=
PKG_ARGS :=
ifneq ($(VERSION),)
PKG_ARGS += --version $(VERSION)
endif
ifneq ($(BUILD),)
PKG_ARGS += --build $(BUILD)
endif

clean-comments:
	@if [ -x "$(COMMENT_CHECKER)" ]; then \
		echo "==> [Comments] Stripping disallowed comments in Sources/..."; \
		"$(COMMENT_CHECKER)" --fix Sources/; \
	else \
		echo "==> [Comments] Note: $(COMMENT_CHECKER) not found, skipping."; \
	fi

check-comments:
	@if [ -x "$(COMMENT_CHECKER)" ]; then \
		echo "==> [Comments] Checking comments policy in Sources/..."; \
		"$(COMMENT_CHECKER)" --check Sources/; \
	else \
		echo "==> [Comments] Note: $(COMMENT_CHECKER) not found, skipping."; \
	fi

checks: clean-comments check-comments
	swift run StewardChecks

build: clean-comments check-comments
	swift build --product ResourceSteward

app: clean-comments check-comments
	./scripts/package-app.sh $(PKG_ARGS)

run: app
	open dist/ResourceSteward.app

dev: checks build
