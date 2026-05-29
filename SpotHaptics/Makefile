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

# ── PATH / ldid signing bridge ─────────────────────────────────────────────
#
# WHY THIS EXISTS:
# Theos's signing step runs ldid inside a bash subshell spawned by make.
# That subshell only inherits the PATH that was visible to `make` at
# startup — it does NOT automatically see /opt/homebrew/bin on a fresh
# GitHub Actions macOS runner unless it is explicitly exported here.
#
# The `:=` operator (simple/immediate expansion) is intentional for PATH:
# it captures the CURRENT value of $(PATH) at parse time, which avoids
# creating a self-referencing recursive variable.  For LDID, := vs = is
# functionally identical (no variable references in the RHS), but := is
# used for consistency.
#
# Note: The primary fix is `brew install ldid` in the workflow.  These
# exports are belt-and-suspenders: they ensure every recipe subshell and
# Theos's internal signing.mk can resolve ldid even if the outer PATH
# state is not ideal.
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
export LDID := /opt/homebrew/bin/ldid
# ──────────────────────────────────────────────────────────────────────────

include $(THEOS)/makefiles/tweak.mk
