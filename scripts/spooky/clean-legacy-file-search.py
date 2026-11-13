#!/usr/bin/env python3
"""Remove obsolete indexer files from incremental app builds before signing."""

from pathlib import Path
import os
import shutil


def clean(contents: Path) -> None:
    for relative in ("Helpers/spooky-fsearch", "Resources/FSearch"):
        path = contents / relative
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


if __name__ == "__main__":
    clean(Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"])
