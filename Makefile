.PHONY: test deps clean

ROCKS := .rocks
LUAROCKS := luarocks --tree $(ROCKS) --lua-version 5.1

test: deps
	eval "$$($(LUAROCKS) path)" && PATH="$(ROCKS)/bin:$$PATH" busted $(BUSTED_ARGS) </dev/null

deps: $(ROCKS)/bin/busted $(ROCKS)/bin/nlua

$(ROCKS)/bin/busted:
	$(LUAROCKS) install busted

$(ROCKS)/bin/nlua:
	$(LUAROCKS) install nlua

clean:
	rm -rf $(ROCKS)
