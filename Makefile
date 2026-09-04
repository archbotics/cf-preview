.POSIX:
.PHONY: help test check

help:
	@echo "make test   run the offline test suite (test/run.sh)"
	@echo "make check  syntax-check every script, and shellcheck it if installed"

test:
	./test/run.sh

check:
	@for f in cf-preview test/run.sh test/stubs/*; do bash -n "$$f" && echo "syntax ok: $$f"; done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck cf-preview test/run.sh test/stubs/*; \
		echo "shellcheck ok"; \
	else \
		echo "shellcheck not installed, skipped"; \
	fi
