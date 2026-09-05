# Decoder regression samples (test target only)

RAR files: https://github.com/mtgto/Unrar.swift at `7216007a38ac122dbdeae26cfdaf7f10775c868f`, `Tests/UnrarTests/fixture`. Encrypted samples use `password`. Include RAR4/RAR5, Unicode names, encrypted data/header, corrupt CRC and unsupported multi-volume input.

MOBI files: https://github.com/bfabiszewski/libmobi, `tests/samples`: `sample-obfuscated-fonts` is KF8 (MOBI version 8); `sample-unicode-huffdic` exercises HuffDic; `sample-textread` is PalmDOC. Source license copied alongside. These are never included in the application target.

Other test content (TXT, EPUB, WAV, PDF, MOBI, Print Replica AZW4) is authored/generated inside `ReadingToolsTests.swift`; the EPUB contains a deliberately blocked script.
