.PHONY: test format

test:
	nvim --headless -u NONE -l tests/unit.lua
	nvim --headless -u NONE -l tests/integration.lua

format:
	stylua lua tests
