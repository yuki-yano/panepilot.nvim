.PHONY: deps test format format-check

deps:
	./scripts/bootstrap_deps.sh

test:
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua dofile('scripts/minitest.lua')"

format:
	stylua lua tests scripts

format-check:
	stylua --check lua tests scripts
