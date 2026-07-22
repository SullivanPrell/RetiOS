# RetiOS local build helpers.
#
# Builds are reproducible: they use the exact package versions pinned in the
# committed lockfile (./Package.resolved). `make ci` runs the very same
# scripts/ci.sh that GitHub Actions runs, so a green `make ci` means a green CI.

.PHONY: ci uitest mac-screens generate update help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

ci: ## Reproduce CI: build the pinned lockfile versions (iOS Simulator). Run before pushing.
	./scripts/ci.sh

uitest: ## Run the XCUITest suite on an iOS Simulator (catches @Environment injection traps)
	./scripts/uitest.sh

mac-screens: ## Screenshot every top-level macOS screen into /tmp/retios-mac (for reviewing Mac layout)
	./scripts/mac-screens.sh

generate: ## Generate RetiOS.xcodeproj from project.yml + install the pinned lockfile (for Xcode)
	./scripts/generate.sh

update: ## Bump packages to the latest in-range versions, verify the build, rewrite Package.resolved
	./scripts/update-packages.sh
