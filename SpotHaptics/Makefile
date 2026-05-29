TARGET := iphone:clang:latest:14.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotHaptics

# SpotHapticsHooks.x.swift goes through the Logos/Orion preprocessor (*.x.swift
# extension is the Theos convention for Orion hook files).
#
# IMPORTANT — do NOT add SpotHapticsHooks_x.swift here.
# That file was a draft fix with a method_exchangeImplementations infinite-
# recursion bug and is now superseded by the corrected SpotHapticsHooks.x.swift.
# It has been archived in the repo for reference only.
SpotHaptics_FILES      = SpotHapticsHooks.x.swift HapticEngine.swift
SpotHaptics_FRAMEWORKS = CoreHaptics UIKit Foundation
SpotHaptics_LOGOSFLAGS = -c orion
SpotHaptics_CFLAGS     = -fobjc-arc
SpotHaptics_SWIFTFLAGS = -I.

# ── PATH / ldid signing bridge ─────────────────────────────────────────────
#
# WHY THIS EXISTS:
# Theos's signing step runs ldid inside a bash subshell spawned by make.
# That subshell only inherits the PATH visible to `make` at startup — it does
# NOT automatically see /opt/homebrew/bin on a fresh GitHub Actions macOS
# runner unless exported here.
#
# := (immediate expansion) is intentional for PATH: captures the current value
# at parse time, preventing a self-referencing recursive variable.
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
export LDID := /opt/homebrew/bin/ldid
# ──────────────────────────────────────────────────────────────────────────

include $(THEOS)/makefiles/tweak.mk
