.PHONY: help build test hooks-test smoke lint coverage check app run install-hooks install-login clean

help:  ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

build:  ## debug build
	swift build

test:  ## unit tests (ClaudeBarCore)
	swift test

hooks-test:  ## tests for hooks/*.sh (no GUI needed)
	Tests/hooks.sh

smoke:  ## launch the real binary against a fake home and check the menu bar items (needs a GUI session)
	Tests/smoke.sh

lint:  ## swiftlint
	swiftlint lint --quiet --strict

coverage:  ## unit tests with a coverage gate on ClaudeBarCore
	scripts/coverage.sh

check: lint coverage hooks-test smoke  ## everything, as run before a commit

app:  ## release build + ClaudeBar.app bundle
	scripts/build.sh

run: app  ## build and open the app (newest launch replaces older copies)
	open ClaudeBar.app

install-hooks:  ## register the Claude Code hooks (scripts/install-hooks.sh status|remove)
	scripts/install-hooks.sh

install-login:  ## start ClaudeBar at login
	scripts/install-login.sh

clean:
	swift package clean
	rm -rf ClaudeBar.app coverage
