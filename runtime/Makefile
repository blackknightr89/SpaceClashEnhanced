# scenh.dll — runtime de mejoras de Space Clash. Requiere MinGW-w64 (i686):
#   Arch: pacman -S mingw-w64-gcc    Debian/Ubuntu: apt install gcc-mingw-w64-i686
ifeq ($(origin CC),default)
CC       = i686-w64-mingw32-gcc
endif
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
ALL_CFLAGS = -std=c11 -O2 -Wall -Wextra -DSCENH_VERSION='"$(VERSION)"' $(CFLAGS)
ALL_LDFLAGS = -shared -static-libgcc -Wl,--enable-stdcall-fixup -s $(LDFLAGS)
LIBS     = -luser32 -lgdi32 -lwinmm -lkernel32
SRC      = $(wildcard src/*.c)

build/scenh.dll: $(SRC) src/scenh.h scenh.def
	mkdir -p build
	$(CC) $(ALL_CFLAGS) -o $@ $(SRC) scenh.def $(ALL_LDFLAGS) $(LIBS)

clean:
	rm -rf build
.PHONY: clean
