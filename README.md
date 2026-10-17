# Dialogs++ for The Blood of Dawnwalker

Descriptions here - [nexus](https://www.nexusmods.com/thebloodofdawnwalker/mods/756)

## File verification

```
FB9D0E5082FC3A4C6E978BC91044D33074347454BB48F2997E41B6F2B7267F13  dialogs++.dll
```

Check your copy after downloading:

- PowerShell: `Get-FileHash .\dialogs++.dll -Algorithm SHA256`
- cmd: `certutil -hashfile dialogs++.dll SHA256`

The hash also lives in `checksums.sha256` and changes with every release.

## Build

Needs Visual Studio 2022 Build Tools with the C++ workload.

```
cl /nologo /std:c++20 /EHsc /W3 /O2 /DUNICODE /D_UNICODE ^
   /Fe:dialogs++.dll src\dw_dialogue_wheel\dialogs++.cpp ^
   /link /DLL user32.lib
```