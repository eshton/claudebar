.PHONY: help setup build test scripts-test hooks-test smoke lint coverage check app run install-hooks install-login uninstall release clean

help:  ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

setup:  ## one-time: check tools, install the git pre-commit hook
	@command -v swiftlint >/dev/null || { echo "missing swiftlint: brew install swiftlint"; exit 1; }
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
	@echo "pre-commit hook installed (lint + unit tests). make check runs everything."

build:  ## debug build
	swift build

test:  ## unit tests (ClaudeBarCore)
	swift test

scripts-test:  ## tests for the hook, release and uninstall scripts (no GUI needed)
	Tests/hooks.sh
	Tests/release.sh
	Tests/uninstall.sh

hooks-test:  ## tests for hooks/*.sh only
	Tests/hooks.sh

smoke:  ## launch the real binary against a fake home and check the menu bar items (needs a GUI session)
	Tests/smoke.sh

lint:  ## swiftlint
	swiftlint lint --quiet --strict

coverage:  ## unit tests with a coverage gate on ClaudeBarCore
	scripts/coverage.sh

check: lint coverage scripts-test smoke  ## everything, as run before a release

app:  ## release build + ClaudeBar.app bundle
	scripts/build.sh

run: app  ## build and open the app (newest launch replaces older copies)
	open ClaudeBar.app

install-hooks:  ## register the Claude Code hooks (scripts/install-hooks.sh status|remove)
	scripts/install-hooks.sh

install-login:  ## start ClaudeBar at login
	scripts/install-login.sh

uninstall:  ## remove hooks, login item and installed scripts (keeps settings; scripts/uninstall.sh --purge for all)
	scripts/uninstall.sh

release:  ## cut a release: make release VERSION=X.Y.Z (runs check, bumps, dates CHANGELOG, tags; never pushes)
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z"; exit 2; }
	scripts/release.sh $(VERSION)

clean:
	swift package clean
	rm -rf ClaudeBar.app coverage
