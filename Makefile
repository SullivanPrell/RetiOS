# RetiOS local build helpers.
#
# Builds are reproducible: they use the exact package versions pinned in the
# committed lockfile (./Package.resolved). `make ci` runs the very same
# scripts/ci.sh that GitHub Actions runs, so a green `make ci` means a green CI.

.PHONY: ci test uitest mac-screens generate update help \
	fmt check swift-fmt swift-fmt-check update-licenses check-licenses lint-docs pre-commit

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

ci: ## Reproduce CI: build the pinned lockfile versions (iOS Simulator). Run before pushing.
	./scripts/ci.sh

test: ## Run the unit-test suite on an iOS Simulator
	./scripts/test.sh

uitest: ## Run the XCUITest suite on an iOS Simulator (catches @Environment injection traps)
	./scripts/uitest.sh

mac-screens: ## Screenshot every top-level macOS screen into /tmp/retios-mac (for reviewing Mac layout)
	./scripts/mac-screens.sh

generate: ## Generate RetiOS.xcodeproj from project.yml + install the pinned lockfile (for Xcode)
	./scripts/generate.sh

update: ## Bump packages to the latest in-range versions, verify the build, rewrite Package.resolved
	./scripts/update-packages.sh

SWIFT     ?= swift
SWIFT_SRC  = RetiOS RetiOSTests RetiOSUITests YggdrasilTunnel

fmt: swift-fmt update-licenses ## Reformat sources in place and apply any missing license headers

check: swift-fmt-check check-licenses lint-docs ## Verify formatting, headers and prose, changing nothing

swift-fmt:
	$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

swift-fmt-check:
	$(SWIFT) format lint --recursive --strict --configuration .swift-format-nolint $(SWIFT_SRC)

update-licenses:
	python3 scripts/license-headers.py $(SWIFT_SRC) scripts

check-licenses:
	python3 scripts/license-headers.py --check $(SWIFT_SRC) scripts

lint-docs: ## Google developer documentation style, over comments and Markdown
	vale $(SWIFT_SRC) docs *.md

pre-commit: check ci ## Run the full local gate before pushing
