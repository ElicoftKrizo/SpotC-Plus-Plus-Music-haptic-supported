# SpotHaptics/Makefile
# ─────────────────────────────────────────────────────────────────────────────
# Theos makefile for the SpotHaptics tweak.
#
# Build requirements:
#   - Theos (https://theos.dev)  with Swift support
#   - Orion framework  (https://orion.theos.dev)
#   - iOS 13+ SDK
#
# Build commands:
#   make                      # debug build
#   make package              # produces a .deb ready for Cyan injection
#   make FINALPACKAGE=1       # release (stripped) build
# ─────────────────────────────────────────────────────────────────────────────

# ── Theos configuration ───────────────────────────────────────────────────────

# Point to your Theos installation; override with THEOS env var if needed
THEOS          ?= /opt/theos
THEOS_MAKE_PATH = $(THEOS)/makefiles

# Deployment target – must be ≥ 13.0 for CoreHaptics
TARGET          := iphone:clang:latest:13.0
ARCHS           := arm64

# ── Package metadata ──────────────────────────────────────────────────────────

PACKAGE_VERSION        := 1.0.0

# ── Tweak definition ──────────────────────────────────────────────────────────

TWEAK_NAME        := SpotHaptics

# Orion processes .x.swift files; plain .swift files are compiled directly
SpotHaptics_FILES  := \
    Sources/SpotHaptics/SpotHapticsHooks.x.swift \
    Sources/SpotHaptics/HapticEngine.swift

# Frameworks required at link time
SpotHaptics_FRAMEWORKS       := CoreHaptics UIKit Foundation
SpotHaptics_PRIVATE_FRAMEWORKS :=

# Link against Orion (provided by the Theos vendor/lib path)
SpotHaptics_LIBRARIES        := orion

# Swift compiler flags
SpotHaptics_SWIFT_FLAGS      := -enable-library-evolution

# The tweak injects into Spotify only
SpotHaptics_BUNDLE_ID        := com.spotify.client
SpotHaptics_INSTALL_PATH     := /Library/MobileSubstrate/DynamicLibraries

# ── Include Theos makefiles ───────────────────────────────────────────────────

include $(THEOS_MAKE_PATH)/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# ── SPM integration (for Xcode / IDE support) ─────────────────────────────────
spm:
	@$(THEOS)/bin/orion-spm $(THEOS) $(SDKPATH) .theos/spm_config
	@echo "SPM config written to .theos/spm_config"
