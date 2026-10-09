ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
AICI_ROOT ?= $(ROOT)/.ai-ci-ick
include $(AICI_ROOT)/ick-android/Makefile
.DEFAULT_GOAL := arena
BUILD ?= $(ROOT)/build/android-$(ABI)
ANDROID_API ?= 26
APP_NDK_CC = $(NDK_BIN)/$(NDK_TARGET_$(ABI))$(ANDROID_API)-clang
APP_C_FLAGS = $(ICK_NDK_BASE_FLAGS) -D__ANDROID_API__=$(ANDROID_API) -D__ANDROID_MIN_SDK_VERSION__=$(ANDROID_API) -std=c11 -O2 -Wall -Wextra -Werror
OUTPUT ?= $(BUILD)/libappendfat_arena_app.so

.PHONY: arena arena-cli mv validate-app
validate-app:
	test -x "$(ICK_COMPILER)"
	test "$$($(ICK_COMPILER) $(ICK_EXTRA_FLAGS) -dumpmachine)" = "$(GNU_TARGET)"
	test -f "$(ICK_BUILTIN_INCLUDE)/stddef.h"
	test -x "$(APP_NDK_CC)"
	mkdir -p "$(BUILD)" "$(dir $(OUTPUT))"

arena: validate-app
	"$(ICK_COMPILER)" $(ICK_EXTRA_FLAGS) $(APP_C_FLAGS) -fPIC -I"$(ROOT)/lib" -S "$(ROOT)/lib/appendfat_arena.c" -o "$(BUILD)/arena.s"
	"$(ICK_COMPILER)" $(ICK_EXTRA_FLAGS) $(APP_C_FLAGS) -fPIC -I"$(ROOT)/lib" -DTARGET_ABI='"$(ABI)"' -S "$(ROOT)/android/arena-c67/jni/arena_app.c" -o "$(BUILD)/app.s"
	"$(APP_NDK_CC)" $(TARGET_FLAGS) -fPIC -c "$(BUILD)/arena.s" -o "$(BUILD)/arena.o"
	"$(APP_NDK_CC)" $(TARGET_FLAGS) -fPIC -c "$(BUILD)/app.s" -o "$(BUILD)/app.o"
	"$(APP_NDK_CC)" -shared "$(BUILD)/arena.o" "$(BUILD)/app.o" -o "$(OUTPUT)" -landroid -llog

arena-cli: OUTPUT = $(BUILD)/appendfat_arena
arena-cli: validate-app
	"$(ICK_COMPILER)" $(ICK_EXTRA_FLAGS) $(APP_C_FLAGS) -Wpedantic -fPIE -I"$(ROOT)/lib" -S "$(ROOT)/lib/appendfat_arena.c" -o "$(BUILD)/arena-cli-lib.s"
	"$(ICK_COMPILER)" $(ICK_EXTRA_FLAGS) $(APP_C_FLAGS) -Wpedantic -fPIE -I"$(ROOT)/lib" -S "$(ROOT)/tools/appendfat_arena.c" -o "$(BUILD)/arena-cli.s"
	"$(APP_NDK_CC)" $(TARGET_FLAGS) -fPIE -c "$(BUILD)/arena-cli-lib.s" -o "$(BUILD)/arena-cli-lib.o"
	"$(APP_NDK_CC)" $(TARGET_FLAGS) -fPIE -c "$(BUILD)/arena-cli.s" -o "$(BUILD)/arena-cli.o"
	"$(APP_NDK_CC)" -pie "$(BUILD)/arena-cli-lib.o" "$(BUILD)/arena-cli.o" -o "$(OUTPUT)"

mv: OUTPUT = $(BUILD)/appendfat_mv
mv: validate-app
	"$(ICK_COMPILER)" $(ICK_EXTRA_FLAGS) $(APP_C_FLAGS) -Wpedantic -mthumb -march=armv7-a -fPIE -S "$(ROOT)/tools/appendfat_mv.c" -o "$(BUILD)/mv.s"
	"$(APP_NDK_CC)" -mthumb -march=armv7-a -fPIE -c "$(BUILD)/mv.s" -o "$(BUILD)/mv.o"
	"$(APP_NDK_CC)" -pie "$(BUILD)/mv.o" -o "$(OUTPUT)"
