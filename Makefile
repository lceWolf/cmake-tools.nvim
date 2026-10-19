.PHONY: test deps clean

ROCKS := .rocks
LUAROCKS := luarocks --tree $(ROCKS) --lua-version 5.1

test: deps
	eval "$$($(LUAROCKS) path)" && PATH="$(ROCKS)/bin:$$PATH" busted $(BUSTED_ARGS)

deps: $(ROCKS)/bin/busted $(ROCKS)/bin/nlua $(ROCKS)/lib/luarocks/rocks-5.1/plenary.nvim

$(ROCKS)/bin/busted:
	$(LUAROCKS) install busted

$(ROCKS)/bin/nlua:
	$(LUAROCKS) install nlua

$(ROCKS)/lib/luarocks/rocks-5.1/plenary.nvim:
	$(LUAROCKS) install plenary.nvim

clean:
	rm -rf $(ROCKS)
