#!/usr/bin/env python3
"""Package the original light icon and native glass vector layers offline.

Edit docs/design/assets/soulo-ring-vector.svg, not the generated package.
The reference PNG is preserved; Default removes its neutral gray background
cast locally, with native 122% scale and a pure-white interior and exterior.
Dark and Mono use separate SVG ribbons and details with native glass styling.
"""
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/design/assets/soulo-ring-vector.svg"
ORIGINAL = ROOT / "docs/design/assets/soulo-icon-original.png"
ICONS = ROOT / "Soulo/Resources/AppIcons"


def main():
    svg = ET.parse(SOURCE).getroot()
    assert svg.attrib["viewBox"] == "0 0 1024 1024"
    assert not any(node.tag.rsplit("}", 1)[-1] in {"image", "filter"} for node in svg.iter()), "Keep the artwork vector-only and free of baked blur"
    assert not any("stroke" in node.attrib for node in svg.iter()), "Outline highlight strokes: native SVG import may fill open stroke contours"
    folder = ICONS / "SouloGlass.icon"
    (folder / "Assets").mkdir(parents=True, exist_ok=True)
    assets = folder / "Assets"
    # Preserve colored gold and its antialiased edges. The reference's central
    # neutral gray wash is background, not a logo stroke; blend that wash to
    # the same white as the outer canvas without changing the gold contours.
    original = Image.open(ORIGINAL).convert("RGB")
    cleaned = []
    for pixel in original.getdata():
        chroma = max(pixel) - min(pixel)
        amount = max(0.0, min(1.0, (chroma - 8) / 10))
        amount = amount * amount * (3 - 2 * amount)
        cleaned.append(tuple(round(255 + (channel - 255) * amount) for channel in pixel))
    default = Image.new("RGB", original.size)
    default.putdata(cleaned)
    default.save(assets / "Soulo-Default.png")
    # Mono uses the identical vector contours with a brighter luminance range.
    # Override the image, not its fill: a fill override also fills open strokes.
    mono = SOURCE.read_text()
    palette = {
        "#D7B77E": "#DADADA", "#F3E4BA": "#FAFAFA",
        "#CBAB70": "#CCCCCC", "#F7EAC7": "#FFFFFF",
        "#D6B77D": "#E5E5E5", "#FFF3D4": "#FFFFFF",
        "#E7C991": "#E4E4E4", "#F8E9C2": "#FAFAFA",
        "#D5B37A": "#DADADA", "#FFF3CF": "#FFFFFF",
        "#FFF4D5": "#FFFFFF", "#FFF2CC": "#FFFFFF",
        "#B9945B": "#A0A0A0", "#BC9A62": "#A5A5A5",
        "#FFF0C7": "#FFFFFF", "#C6A168": "#B0B0B0"
    }
    for color, gray in palette.items():
        mono = mono.replace(color, gray)
    # Keep the cutout ribbons separate from the narrow highlights. Never
    # override SVG fill in Mono: doing so fills open highlight paths as well.
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    for name, content in [("Gold", SOURCE.read_text()), ("Mono", mono)]:
        tree = ET.fromstring(content)
        group = tree.find("{http://www.w3.org/2000/svg}g")
        for part in ["Ribbons", "Details"]:
            selected = [node for node in group if node.attrib.get("data-layer") == part.lower()]
            assert selected, f"Missing {part} vector layer"
            result = ET.fromstring(content)
            target = result.find("{http://www.w3.org/2000/svg}g")
            target.clear()
            target.set("transform", group.attrib["transform"])
            target.extend(selected)
            (assets / f"Soulo-{part}-{name}.svg").write_text(ET.tostring(result, encoding="unicode") + "\n")
    # Remove only this generator's obsolete raster, never other artwork.
    for obsolete in ["Soulo-Ring.png", "Soulo-Ring.svg", "Soulo-Ring-Mono.svg", "Soulo-Original.png"]:
        (assets / obsolete).unlink(missing_ok=True)
    original_visibility = [
        {"value": False}, {"appearance": "dark", "value": True},
        {"appearance": "tinted", "value": True}
    ]
    vector_visibility = [
        {"value": True}, {"appearance": "dark", "value": False},
        {"appearance": "tinted", "value": False}
    ]
    def vector_layer(part, glass):
        return {
            "image-name-specializations": [
                {"value": f"Soulo-{part}-Gold.svg"},
                {"appearance": "tinted", "value": f"Soulo-{part}-Mono.svg"}
            ], "name": part, "glass": glass
        }
    doc = {
        "fill": {"solid": "extended-srgb:1.00000,1.00000,1.00000,1.00000"},
        "fill-specializations": [{"appearance": "dark", "value": {
            "linear-gradient": ["srgb:0.13,0.12,0.10,1", "srgb:0.035,0.03,0.025,1"]
        }}],
        "groups": [{
            "name": "Original contours · White Default",
            "layers": [{"image-name": "Soulo-Default.png", "name": "Original gold on pure white", "glass": False,
                "position": {"scale": 1.22, "translation-in-points": [0, 0]}}],
            "hidden-specializations": original_visibility,
            "shadow": {"kind": "none", "opacity": 0}, "specular": False,
            "blur-material": 0, "translucency": {"enabled": False, "value": 0}
        }, {
            "name": "Vector ribbons · Dark and Mono",
            "layers": [vector_layer("Ribbons", True)],
            "hidden-specializations": vector_visibility,
            "specular": True, "blur-material": 0,
            "shadow": {"kind": "neutral", "opacity": 0.12},
            "translucency": {"enabled": True, "value": 0.08}
        }, {
            "name": "Vector details · Dark and Mono",
            "layers": [vector_layer("Details", False)],
            "hidden-specializations": vector_visibility,
            "specular": False, "blur-material": 0,
            "shadow": {"kind": "none", "opacity": 0},
            "translucency": {"enabled": False, "value": 0}
        }],
        "supported-platforms": {"squares": "shared"}
    }
    (folder / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")
    assert default.getpixel((512, 512)) == default.getpixel((0, 0)) == (255, 255, 255)
    print("Packaged original gold contours on pure white at 122%; transparent vector strands for Dark/Mono")


if __name__ == "__main__":
    main()
