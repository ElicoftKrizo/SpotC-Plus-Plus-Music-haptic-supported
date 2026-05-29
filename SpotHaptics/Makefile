TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

# Identify source files
SpotHaptics_FILES = SpotHapticsHooks.x.swift HapticEngine.swift
SpotHaptics_FRAMEWORKS = CoreHaptics UIKit Foundation

# Automatic Orion engine components linkage
SpotHaptics_LOGOSFLAGS = -c orion
SpotHaptics_CFLAGS = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

# FIX: Force Theos to look in the Homebrew bin directory for ldid!
export LDID = /opt/homebrew/bin/ldid

include $(THEOS)/makefiles/tweak.mk
