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

# FIX: Add Homebrew bin directory to PATH for ldid to be found globally
export PATH := /opt/homebrew/bin:$(PATH)
export LDID = /opt/homebrew/bin/ldid

include $(THEOS)/makefiles/tweak.mk
