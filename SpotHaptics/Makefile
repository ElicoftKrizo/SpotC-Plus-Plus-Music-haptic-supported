TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

# FIX: Removed "Sources/SpotHaptics/" so it finds the files right in the main folder!
SpotHaptics_FILES = SpotHapticsHooks.x.swift HapticEngine.swift
SpotHaptics_FRAMEWORKS = CoreHaptics UIKit Foundation
SpotHaptics_LIBRARIES = orion
SpotHaptics_CFLAGS = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

include $(THEOS)/makefiles/tweak.mk
