#!/usr/bin/env python3
"""Stage Chinese-labelled metadata directories into Fastlane's locale-code layout."""
import shutil, tempfile
from pathlib import Path
from app_store_locales import APP_STORE_LOCALE_NAMES

root=Path(__file__).resolve().parent.parent
source=root/"fastlane"/"metadata"
destination=Path(tempfile.mkdtemp(prefix="soulo-fastlane-metadata-"))
for locale,chinese_name in APP_STORE_LOCALE_NAMES.items():
    shutil.copytree(source/chinese_name,destination/locale)
print(destination)
