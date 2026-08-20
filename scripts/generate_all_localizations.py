#!/usr/bin/env python3
"""Generate Soulo runtime strings, permission strings and App Store metadata for 50 locales."""

from __future__ import annotations

import json, re, sys, threading, time, urllib.parse, urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from app_store_locales import APP_STORE_LOCALE_NAMES

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Soulo"
METADATA = ROOT / "fastlane" / "metadata"
CACHE_PATH = Path("/tmp/soulo_translation_cache.json")
LOCALES = OrderedDict([
    ("ar-SA", "ar"), ("bn-BD", "bn"), ("ca", "ca"), ("zh-Hans", "zh-CN"),
    ("zh-Hant", "zh-TW"), ("hr", "hr"), ("cs", "cs"), ("da", "da"),
    ("nl-NL", "nl"), ("en-AU", "en"), ("en-CA", "en"), ("en-GB", "en"),
    ("en-US", "en"), ("fi", "fi"), ("fr-FR", "fr"), ("fr-CA", "fr"),
    ("de-DE", "de"), ("el", "el"), ("gu-IN", "gu"), ("he", "he"),
    ("hi", "hi"), ("hu", "hu"), ("id", "id"), ("it", "it"), ("ja", "ja"),
    ("kn-IN", "kn"), ("ko", "ko"), ("ms", "ms"), ("ml-IN", "ml"),
    ("mr-IN", "mr"), ("no", "no"), ("or-IN", "or"), ("pl", "pl"),
    ("pt-BR", "pt"), ("pt-PT", "pt"), ("pa-IN", "pa"), ("ro", "ro"),
    ("ru", "ru"), ("sk", "sk"), ("sl-SI", "sl"), ("es-MX", "es"),
    ("es-ES", "es"), ("sv", "sv"), ("ta-IN", "ta"), ("te-IN", "te"),
    ("th", "th"), ("tr", "tr"), ("uk", "uk"), ("ur-PK", "ur"), ("vi", "vi"),
])
LEGACY = {"ar-SA":"ar", "fr-FR":"fr", "de-DE":"de", "es-ES":"es", **{x:x for x in ("zh-Hans","zh-Hant","it","ja","ko","pt-BR","ru","th","tr","vi")}}
STRINGS_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
PLACEHOLDER_RE = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGcCsSpaA%]')
PROTECTED = ["Soulo", "App Store", "Live Text", "Control Center", "Dynamic Island", "Siri", "Shortcuts", "Spotlight", "iCloud", "UserScript", "WebExtension", "Face ID", "Touch ID"]
lock = threading.Lock()
try: CACHE = json.loads(CACHE_PATH.read_text())
except Exception: CACHE = {}

INFO = OrderedDict([
    ("CFBundleDisplayName", "Soulo"),
    ("NSCameraUsageDescription", "Allow camera access when you approve a website request, such as for video calls, scanning codes, or taking a photo."),
    ("NSMicrophoneUsageDescription", "Allow microphone access for voice search and, when you approve, website calls or recording."),
    ("NSSpeechRecognitionUsageDescription", "Allow speech recognition to turn your voice into search text."),
    ("NSPhotoLibraryUsageDescription", "Soulo needs photo library access to set a custom wallpaper."),
    ("NSPhotoLibraryAddUsageDescription", "Soulo needs permission to save web images to your photo library."),
])
META = OrderedDict([
    ("name.txt", "Soulo: Multi-Search Browser"),
    ("subtitle.txt", "Search Web, Social & AI"),
    ("promotional_text.txt", "Search 40+ web, social, video, shopping and AI platforms in one private browser with tabs, extensions, ad blocking and powerful webpage tools."),
    ("description.txt", """Soulo is a fast, private multi-search browser for iPhone and iPad. Enter one query, then switch between more than 40 search, social, video, shopping, knowledge and AI platforms without retyping.\n\nBROWSE YOUR WAY\n• Tabs, bookmarks, history, downloads and customizable search platforms\n• Private browsing, tracker protection, ad blocking and per-site controls\n• Mobile and desktop website modes, page zoom, translation and full-page capture\n• Download images, video, audio and documents with the webpage resource inspector\n• Extract text from webpage images with Live Text\n\nBUILT FOR iPHONE AND iPAD\n• Multiple independent windows on iPad\n• Share links or text directly to Soulo\n• Search and open downloads from Siri, Shortcuts, Control Center, the Lock Screen and Action Button\n• Background downloads with real progress and pause/resume\n• Live Activities and Dynamic Island status\n\nEXTEND THE WEB\nInstall UserScripts or compatible WebExtensions, manage permissions clearly, and create your own scripts with the built-in API documentation.\n\nSoulo stores browsing data locally unless you enable iCloud settings sync. Private browsing does not save history."""),
    ("release_notes.txt", """What’s New:\n\n• Share links and text to Soulo from other apps.\n• Extract text from webpage images with Live Text.\n• Added Control Center, Lock Screen, Action Button, Siri and Shortcuts actions.\n• Downloads now continue in the background with real progress and pause/resume.\n• Added independent multi-window browsing on iPad.\n• Enabled compatible native WebExtensions alongside UserScripts.\n• Expanded the app and App Store information to all 50 supported App Store locales."""),
    ("keywords.txt", "browser,search,private,tabs,web,AI,social,video,download,adblock,userscript,translate"),
])

def load(path):
    if not path.exists(): return OrderedDict()
    return OrderedDict((m.group(1), m.group(2).replace(r'\n','\n').replace(r'\"','"').replace(r'\\','\\')) for m in STRINGS_RE.finditer(path.read_text(encoding="utf-8")))

def sanitize(value):
    value=re.sub(r'^\|\s*(?:\\n)?\s*','',value.strip())
    value=re.sub(r'\s*\|$','',value)
    for character in ("\u00ad", "\u200b", "\u2060", "\ufeff"):
        value=value.replace(character,"")
    return value.strip()
def esc(value): return value.replace('\\',r'\\').replace('"',r'\"').replace('\n',r'\n')
def write(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("/* Soulo — generated and validated localization */\n\n" + "\n".join(f'"{esc(k)}" = "{esc(sanitize(v))}";' for k,v in values.items()) + "\n", encoding="utf-8")

def request(text, target):
    if target == "en" or not text.strip(): return text
    key = target + "\0" + text
    with lock:
        if key in CACHE: return CACHE[key]
    url = "https://translate.googleapis.com/translate_a/single?" + urllib.parse.urlencode({"client":"gtx","sl":"en","tl":target,"dt":"t","q":text})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=40) as response: payload=json.loads(response.read())
            result="".join(part[0] for part in payload[0] if part and part[0])
            with lock: CACHE[key]=result
            return result
        except Exception as error:
            if attempt == 4: raise RuntimeError(f"translate {target}: {error}")
            time.sleep(1.5*(attempt+1))

def marker(identifier):
    spacing=r"[\s\u200b-\u200f\u202a-\u202e\u2060\ufeff]*"; quote=r'["\'“”‘’]'
    return rf"<{spacing}x{spacing}id{spacing}={spacing}{quote}{identifier}{quote}{spacing}/{spacing}>"

def protect(value):
    found=[]; pattern=re.compile("|".join([PLACEHOLDER_RE.pattern]+[re.escape(x) for x in PROTECTED]))
    return pattern.sub(lambda m: found.append(m.group(0)) or f'<x id="P{len(found)-1:04d}"/>',value),found

def translate(values, target):
    if target=="en": return values
    output=[]; start=0
    while start<len(values):
        batch=[]; size=0
        while start+len(batch)<len(values):
            value=values[start+len(batch)]
            if batch and size+len(value)>2800: break
            batch.append(value); size+=len(value)+32
        protected=[]; maps=[]
        for value in batch:
            item,found=protect(value); protected.append(item); maps.append(found)
        separators=[f"S{i:04d}" for i in range(len(batch)-1)]
        combined=protected[0]
        for separator,item in zip(separators,protected[1:]): combined+=f'\n<x id="{separator}"/>\n{item}'
        translated=request(combined,target)
        pieces=re.split("|".join(marker(x) for x in separators),translated) if separators else [translated]
        if len(pieces)!=len(batch): pieces=[request(item,target) for item in protected]
        for value,found in zip(pieces,maps):
            for i,item in enumerate(found): value=re.sub(marker(f"P{i:04d}"),lambda _:item,value,flags=re.I)
            output.append(value.strip())
        start+=len(batch)
    return output

def base_for(locale, english):
    current=load(RESOURCES/f"{locale}.lproj"/"Localizable.strings")
    if not current and locale in LEGACY: current=load(RESOURCES/f"{LEGACY[locale]}.lproj"/"Localizable.strings")
    return OrderedDict((k,current[k]) for k in english if k in current)

def generate(locale,target):
    english=load(RESOURCES/"en.lproj"/"Localizable.strings"); values=base_for(locale,english)
    missing=[k for k in english if k not in values]
    for key,value in zip(missing,translate([english[k] for k in missing],target)): values[key]=value
    write(RESOURCES/f"{locale}.lproj"/"Localizable.strings",OrderedDict((k,values[k]) for k in english))
    info=translate(list(INFO.values()),target); info[0]="Soulo"
    write(RESOURCES/f"{locale}.lproj"/"InfoPlist.strings",OrderedDict(zip(INFO,info)))
    meta_dir=METADATA/APP_STORE_LOCALE_NAMES[locale]; meta_dir.mkdir(parents=True,exist_ok=True)
    translated=translate(list(META.values()),target)
    limits={"name.txt":30,"subtitle.txt":30,"promotional_text.txt":170,"keywords.txt":100}
    for (filename,_),value in zip(META.items(),translated):
        value=sanitize(value)
        if filename=="keywords.txt": value=value.replace("，",",").replace(", ",",")
        if filename in limits: value=value[:limits[filename]].rstrip(" ,·-—")
        (meta_dir/filename).write_text(value.strip()+"\n",encoding="utf-8")
    return locale

def markdown():
    lines=["# Soulo 1.1.4 App Store Metadata — 50 Languages",""]
    for locale,chinese in APP_STORE_LOCALE_NAMES.items():
        lines += [f"## {chinese}（{locale}）",""]
        for filename,label in (("name.txt","名称"),("subtitle.txt","副标题"),("promotional_text.txt","推广文本"),("description.txt","描述"),("release_notes.txt","更新说明"),("keywords.txt","关键词")):
            value=(METADATA/chinese/filename).read_text(encoding="utf-8").strip()
            lines += [f"### {label}","",value,""]
    (ROOT/"AppStore_1.1.4_Metadata.md").write_text("\n".join(lines),encoding="utf-8")

def main():
    chosen={x for x in sys.argv[1:] if not x.startswith("--")}
    locales=OrderedDict((k,v) for k,v in LOCALES.items() if not chosen or k in chosen)
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(generate,k,v):k for k,v in locales.items()}
        for future in as_completed(futures): print("generated",future.result(),flush=True)
    with lock: CACHE_PATH.write_text(json.dumps(CACHE,ensure_ascii=False))
    if len(locales)==50: markdown()
    print(f"complete: {len(locales)} locales")

if __name__ == "__main__": main()
