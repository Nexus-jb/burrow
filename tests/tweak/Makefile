# SPDX-License-Identifier: Apache-2.0
#
# A sample tweak built with Theos, exactly as tweaks are built today. The
# tests load it unchanged with Burrow in place of Cydia Substrate.
#
#   gmake FINALPACKAGE=1   (needs THEOS set and GNU Make 4)

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BurrowSampleTweak
BurrowSampleTweak_FILES = Tweak.x
BurrowSampleTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
