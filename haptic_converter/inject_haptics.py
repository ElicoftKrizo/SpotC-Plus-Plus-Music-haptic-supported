"""
inject_haptics.py
-----------------
Injects .ahap haptic pattern files into a Spotify IPA archive.

Each .ahap file is placed at:
    Payload/Spotify.app/CustomHaptics/<filename>.ahap

Usage:
    python3 inject_haptics.py <input.ipa> <haptics_dir/> <output.ipa>

    input.ipa   — path to the source IPA (may equal output.ipa for in-place edit)
    haptics_dir — directory containing one or more .ahap files
    output.ipa  — path to write the patched IPA

Exit codes:
    0  success
    1  argument / file error
    2  no .ahap files found in haptics_dir
"""

import os
import sys
import shutil
import zipfile
import tempfile
from pathlib import Path

DEST_PREFIX = "Payload/Spotify.app/CustomHaptics/"


def die(msg: str, code: int = 1) -> None:
    print(f"❌  {msg}", file=sys.stderr)
    sys.exit(code)


def main() -> None:
    if len(sys.argv) != 4:
        die(
            f"Usage: {sys.argv[0]} <input.ipa> <haptics_dir/> <output.ipa>",
            code=1,
        )

    input_ipa  = Path(sys.argv[1])
    haptics_dir = Path(sys.argv[2])
    output_ipa  = Path(sys.argv[3])

    # ── Validate inputs ───────────────────────────────────────────────────────
    if not input_ipa.is_file():
        die(f"Input IPA not found: {input_ipa}")
    if not haptics_dir.is_dir():
        die(f"Haptics directory not found: {haptics_dir}")

    ahap_files = sorted(haptics_dir.glob("*.ahap"))
    if not ahap_files:
        die(f"No .ahap files found in: {haptics_dir}", code=2)

    print(f"📂  Source IPA  : {input_ipa}")
    print(f"🎯  Haptics dir : {haptics_dir}  ({len(ahap_files)} file(s))")
    print(f"📦  Output IPA  : {output_ipa}")
    print()

    # ── Work in a temp file so input == output is safe ────────────────────────
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".ipa")
    os.close(tmp_fd)

    try:
        with zipfile.ZipFile(input_ipa, "r") as src_zip:
            with zipfile.ZipFile(tmp_path, "w",
                                 compression=zipfile.ZIP_DEFLATED,
                                 allowZip64=True) as dst_zip:

                # Copy every existing entry verbatim (preserves compression).
                for item in src_zip.infolist():
                    dst_zip.writestr(item, src_zip.read(item.filename))

                # Inject .ahap files.
                for ahap in ahap_files:
                    dest_path = DEST_PREFIX + ahap.name
                    print(f"  ✚  {dest_path}")
                    dst_zip.write(ahap, arcname=dest_path)

        # Atomic replace: move temp → output (handles input == output).
        shutil.move(tmp_path, output_ipa)
        print()
        print(f"✅  Injected {len(ahap_files)} haptic pattern(s) → {output_ipa}")

    except Exception as exc:
        os.unlink(tmp_path)
        die(f"Failed to patch IPA: {exc}")


if __name__ == "__main__":
    main()
    
