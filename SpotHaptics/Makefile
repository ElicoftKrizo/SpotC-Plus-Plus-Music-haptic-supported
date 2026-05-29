TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

# Identify all Swift source components dynamically
SpotHaptics_FILES = HapticEngine.swift SpotHapticsHooks.x.swift
SpotHaptics_CFLAGS = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

include $(THEOS)/makefiles/tweak.mk
