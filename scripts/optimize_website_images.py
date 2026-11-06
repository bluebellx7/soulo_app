#!/usr/bin/env python3
"""Generate compact website images while retaining the original product assets.

Requires Pillow. Run before scripts/build_website.py when source images change.
"""
import argparse
import io
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'website'
# 108px covers the 36px navigation logo at 3x. The rear phone image is
# displayed at up to 205px; 804px retains ample resolution for high-DPI screens.
ASSETS = (
    ('app-icon.png', 'images/web/app-icon-108.webp', 108, True),
    ('images/search-home.png', 'images/web/search-home.webp', None, True),
    ('images/soulo-home-light-zh.webp', 'images/web/soulo-home-light-zh-804.webp', 804, False),
    ('images/soulo-home-light-en.webp', 'images/web/soulo-home-light-en-804.webp', 804, False),
)
ILLUSTRATIONS = (
    ('About', 'images/web/illustration-about.webp'),
    ('Books', 'images/web/illustration-reading.webp'),
    ('Bookmarks', 'images/web/illustration-bookmarks.webp'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    stale = []
    for source, output, width, lossless in ASSETS:
        original = SITE / source
        target = SITE / output
        with Image.open(original) as image:
            image = image.convert('RGB')
            if width and image.width > width:
                height = round(image.height * width / image.width)
                image = image.resize((width, height), Image.Resampling.LANCZOS)
            encoded = io.BytesIO()
            image.save(encoded, format='WEBP', method=6, lossless=lossless,
                       quality=100 if lossless else 94)
            payload = encoded.getvalue()
            with Image.open(io.BytesIO(payload)) as decoded:
                assert decoded.size == image.size, output
                if lossless:
                    assert decoded.convert('RGB').tobytes() == image.tobytes(), output
        assert len(payload) < original.stat().st_size, output
        if not target.is_file() or target.read_bytes() != payload:
            stale.append(output)
            if not args.check:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
        print(f'{source}: {original.stat().st_size:,} -> {len(payload):,} bytes')
    for scene, output in ILLUSTRATIONS:
        original = ROOT / f'Soulo/Assets.xcassets/Illustration{scene}.imageset/illustration.png'
        target = SITE / output
        with Image.open(original) as source:
            image = source.convert('RGBA')
            image.thumbnail((720, 480), Image.Resampling.LANCZOS)
            encoded = io.BytesIO()
            image.save(encoded, format='WEBP', quality=90, method=6)
            payload = encoded.getvalue()
        assert len(payload) < original.stat().st_size, output
        if not target.is_file() or target.read_bytes() != payload:
            stale.append(output)
            if not args.check:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
        print(f'{scene} illustration: {original.stat().st_size:,} -> {len(payload):,} bytes')
    if args.check and stale:
        parser.exit(1, 'Out-of-date website images: ' + ', '.join(stale) + '\n')


if __name__ == '__main__':
    main()
