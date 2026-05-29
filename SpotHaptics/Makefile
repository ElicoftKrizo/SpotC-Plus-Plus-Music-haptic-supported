TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

# Identify source files directly in the main directory
SpotHaptics_FILES = SpotHapticsHooks.x.swift HapticEngine.swift
SpotHaptics_FRAMEWORKS = CoreHaptics UIKit Foundation

# FIX: Tell Theos to automatically hook up the Orion engine components
SpotHaptics_LOGOSFLAGS = -c orion
SpotHaptics_CFLAGS = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

include $(THEOS)/makefiles/tweak.mk
