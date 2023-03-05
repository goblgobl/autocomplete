F="zac.zig"

.PHONY: t
t:
	zig test ${F}


.PHONY: s
s:
	zig run main.zig
