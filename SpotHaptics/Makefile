TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

SpotHaptics_FILES = Sources/SpotHaptics/SpotHapticsHooks.x.swift Sources/SpotHaptics/HapticEngine.swift
SpotHaptics_FRAMEWORKS = CoreHaptics UIKit Foundation
SpotHaptics_LIBRARIES = orion
SpotHaptics_CFLAGS = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

include $(THEOS)/makefiles/tweak.mk
