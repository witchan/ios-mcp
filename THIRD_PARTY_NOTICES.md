# Third-Party Notices

This document describes third-party open-source components used by iOS MCP.
The MIT License in `LICENSE` applies only to code authored for this project.
The attribution and disclaimer text in `NOTICE` applies to project-owned code.
Third-party components remain licensed under their own licenses.

This is an engineering compliance summary, not legal advice.

## Bundled Or Vendored Components

| Component | Location | Used For | License |
|---|---|---|---|
| AppSync Unified | `AppSync/`, packaged as `mcp-appsync-installd` and `mcp-appsync-frontboard` | IPA signature-check bypass support for development/testing installs | GPL-3.0-or-later. See `AppSync/LICENSE`. |
| appinst | `AppSync/appinst/`, packaged as `mcp-appinst` | Command-line IPA installation helper | GPL-3.0-or-later. Covered by the AppSync project license in `AppSync/LICENSE`. |
| ldid | `third_party/ldid/`, packaged as `mcp-ldid` | Ad-hoc/fake signing helper | AGPL-3.0. See `third_party/ldid/COPYING`. |
| OpenSSL libcrypto | `third_party/procursus-sdk/iphoneos-arm64/usr/include/openssl/` and `third_party/procursus-sdk/iphoneos-arm64/usr/lib/libcrypto.a` | Crypto backend for `mcp-ldid` | Apache-2.0. The vendored headers state OpenSSL 3.2.1 and Apache-2.0. |
| libplist | `third_party/procursus-sdk/iphoneos-arm64/usr/include/plist/` and `third_party/procursus-sdk/iphoneos-arm64/usr/lib/libplist-2.0.a` | Property-list support for `mcp-ldid` | LGPL-2.1-or-later. See license notice in `third_party/procursus-sdk/iphoneos-arm64/usr/include/plist/plist.h`. |
| libzip | `AppSync/appinst/zip.h`; linked from `$(THEOS)/lib/libzip.a` when building `mcp-appinst` and `mcp-roothelper` | IPA/ZIP archive inspection and extraction | BSD-style 3-clause license. See the notice in `AppSync/appinst/zip.h`. |

## External Build Or Runtime Dependencies

These components are required by the build or runtime environment but are not
vendored as project source in this repository unless noted above:

| Component | Used For | Notes |
|---|---|---|
| Theos / Logos | Tweak, tool, and package build system | Build-time dependency. |
| MobileSubstrate / Cydia Substrate / Substitute / ElleKit | Tweak injection runtime | Declared through package dependencies or linked by AppSync subprojects. |
| PreferenceLoader | Settings bundle integration | Runtime package dependency. |
| roothide library | roothide path translation and compatibility | Linked only for roothide builds. |
| zlib, libxml2, iconv | System/SDK libraries used by helpers | Linked as platform libraries. |

## Distribution Requirements

When distributing source or binary builds of iOS MCP:

1. Keep this `THIRD_PARTY_NOTICES.md` file with the distribution.
2. Keep `LICENSE`, `NOTICE`, `AppSync/LICENSE`, and `third_party/ldid/COPYING` available.
3. Provide the corresponding source for modified and bundled GPL/AGPL components, including `AppSync/`, `AppSync/appinst/`, and `third_party/ldid/`.
4. For LGPL components that are statically linked, especially `libplist-2.0.a`, provide the materials required by LGPL for relinking, or change the build to dynamically link an LGPL-compliant system package.
5. Preserve copyright notices and license notices from OpenSSL, libzip, libplist, AppSync, appinst, and ldid.

The generated deb package installs this notice, the main license, and project
attribution notice under:

```text
/usr/share/doc/ios-mcp/
```
