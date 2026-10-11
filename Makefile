CC ?= gcc
CROSS_COMPILE ?=
ifneq ($(CROSS_COMPILE),)
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
endif
LVGL_DIR ?= vendor
LVGL_DIR_NAME ?= lvgl
BUILD_DIR ?= build/$(if $(CROSS_COMPILE),mips32,host)
CFLAGS ?= -O2 -pipe
CPPFLAGS += -Iinclude -Ivendor -DLV_CONF_INCLUDE_SIMPLE
CFLAGS += -std=c11 -Wall -Wextra -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE
LDFLAGS += -pthread
LDLIBS += -lm

LVGL_SOURCES := $(shell find $(LVGL_DIR)/$(LVGL_DIR_NAME)/src -name '*.c' -print)
SOURCES := src/main.c src/platform.c $(LVGL_SOURCES)
OBJECTS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(SOURCES))

.PHONY: all mips32 sdl clean
all: $(BUILD_DIR)/opencreator-installer
mips32:
	$(MAKE) CROSS_COMPILE=mipsel-linux-gnu- BUILD_DIR=build/mips32 \
	  LDFLAGS="-static -pthread" all
sdl:
	$(MAKE) BUILD_DIR=build/sdl CC=gcc \
	  CPPFLAGS="$(CPPFLAGS) $$(pkg-config --cflags sdl2)" \
	  CFLAGS="$(CFLAGS) -DOC_DEMO" \
	  SOURCES="src/main.c src/platform_sdl.c $(LVGL_SOURCES)" \
	  LDLIBS="$(LDLIBS) $$(pkg-config --libs sdl2)" all

$(BUILD_DIR)/opencreator-installer: $(OBJECTS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build
