# RetiOS local build helpers.
#
# `make ci` reproduces the GitHub Actions build (.github/workflows/ci.yml) — it
# runs the very same scripts/ci.sh that CI runs, so a green `make ci` means a
# green CI. Run it before pushing.

.PHONY: ci ci-fast generate help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

ci: ## Reproduce CI: regenerate, resolve to the LATEST in-range packages, build (iOS Simulator)
	FRESH=1 ./scripts/ci.sh

ci-fast: ## Same build, reusing already-resolved packages (fast; may lag CI's versions)
	FRESH=0 ./scripts/ci.sh

generate: ## Just (re)generate RetiOS.xcodeproj from project.yml
	xcodegen generate
