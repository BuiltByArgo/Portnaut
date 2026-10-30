# Third-party components

Portnaut is made by Built by Argo (support: builtbyargo@proton.me). Its original application code and vector artwork are MIT licensed (© 2026 Built by Argo), and Portnaut is distributed free of charge. Assassin's Creed and Ubisoft Connect are Ubisoft trademarks; Steam is a Valve trademark; EA is an Electronic Arts trademark; Apple, Mac, Metal and MetalFX are Apple trademarks. Portnaut is independent of, and not endorsed by, Apple, Ubisoft, Valve, Electronic Arts, CodeWeavers, Highball, and Sikarugir. No game files, credentials, proprietary code of other companies' products, or Apple D3DMetal are included in Portnaut.app. D3DMetal is installed into Portnaut's data folder from the downloaded support archive, as described below, and only as part of this free, non-commercial software.

Compatibility components are downloaded separately from their maintainers. The source folder and Portnaut.app do not redistribute a Wine runtime. The links below identify the exact binary inputs and their corresponding source projects. Any future bundled runtime release must also provide the required licenses, notices, and corresponding sources.

## Wine 11 — Highball x64 r27

- Binary release: https://github.com/gauthierpiarrette/highball-engine/releases/tag/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer
- Archive: `engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer.tar.gz`
- SHA-256: `1d1a130c0108a4bbb88cd289c3c313292868c3b84010eb315801eba43026e3e8`
- Versioned build inputs, patches, and notices: https://github.com/gauthierpiarrette/highball-engine/tree/engine-wine-11.0-20261014T003801Z-0024-app-packages-0023-spatial-mixer
- Wine is LGPL-2.1-or-later. This Intel build uses the Wine sources CodeWeavers publishes under the LGPL, with Highball's LGPL patch series. It runs through Rosetta on Apple Silicon and does not depend on any other installed Wine product.
- Included supporting components have their own licenses; see the release's `NOTICE.md`. These include Wine Mono (MIT), Wine Gecko (MPL), and MoltenVK (Apache-2.0). MSync originated at https://github.com/marzent/wine-msync.

## DXMT — Highball build a444716

- Binary release: https://github.com/gauthierpiarrette/highball-engine/releases/tag/dxmt-highball-20260930T161516Z-a444716
- SHA-256: `96feaf5d98d3c6cdc3edea9503e2891d435df8d5bfdf7d3f6998a56ec62bbd58`
- Corresponding source: https://github.com/gauthierpiarrette/dxmt/tree/a444716
- Upstream project: https://github.com/3Shain/dxmt
- License at the pinned commit: **LGPL-2.1-or-later**, copyright Feifan He for CodeWeavers. The source's LICENSE takes precedence over older manifest descriptions identifying DXMT as MIT.
- Portnaut installs D3D10/11, DXGI and WineMetal into the DXMT renderer copy of the runtime (64-bit Direct3D; WineMetal for both architectures). Since Portnaut 0.5.0 its `nvapi64` and `nvngx` (DXMT's bridge from DLSS to MetalFX) are installed too; Wine keeps NVIDIA's API disabled unless a bottle turns DLSS on. Cross-process swapchains stay off.

## Support libraries and renderers — Template 1.0.11

- Download: https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.11.tar.xz
- SHA-256: `9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a`
- From `Contents/Frameworks`, Portnaut installs the top-level `.dylib` libraries, the GStreamer framework, and three renderers from `renderer/`, each into its own APFS clone of the Wine engine. The proprietary wrapper launcher and Sikarugir SDK are excluded.
- **D3DMetal** (`renderer/d3dmetal`, Game Porting Toolkit 3.0-3): Apple's evaluation environment for Windows games, under Apple's licence (included as `D3DMetal-License.rtf` in the D3DMetal copy). It covers non-commercial use for developing, testing and evaluating games on Apple hardware, and does not allow modification; Portnaut installs the files unmodified, in Apple's `lib/external` and `lib/wine` layout.
- **DXVK** (`renderer/dxvk`, dxvk-macOS async 1.10.3, zlib licence): https://github.com/Gcenx/DXVK-macOS. Portnaut installs `d3d11` and `d3d10core` for both architectures.
- **D9VK** (`renderer/d9vk`, DXVK's Direct3D 9, zlib licence): installed as `d3d9` in the DXVK copy.
- Not installed: `cnc-ddraw` and the template's own DXMT build.
- Source/build references: https://github.com/Sikarugir-App/Sikarugir-foss-sources and https://github.com/Sikarugir-App/Template
- GStreamer and many of its libraries are LGPL; dependent libraries have their own licenses. Preserve the framework's bundled notices. Upstream source: https://gstreamer.freedesktop.org/.
- SDL 2 (`libSDL2-2.0.0.dylib`, zlib licence, https://www.libsdl.org/) is among those libraries; Wine's controller driver loads it.

## Launchers: Ubisoft Connect, Steam, EA app

Each launcher's installer is downloaded from its publisher's HTTPS CDN when the user chooses to install it: Ubisoft (https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe, linked by https://www.ubisoft.com/en-gb/ubisoft-connect/download), Valve (https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe) and Electronic Arts (https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe). These installers change upstream and are not pinned to checksums; Portnaut checks only that a Windows program arrived. Each launcher presents its own terms and account flow. Portnaut never asks for or stores launcher credentials; each launcher keeps its state inside its bottle. Steam, Ubisoft Connect and EA are trademarks of their owners.

Steam's interface fix uses a registry value read by Portnaut's Wine runtime; no Steam files are modified. The EA app installer argument follows Lutris's public EA app script (https://lutris.net/games/ea-app/).

## Apple system components

SwiftUI, AppKit, Metal, and Rosetta are supplied under Apple's terms. Rosetta is a dependency of this first runtime. Future macOS compatibility requires separate validation.

## Microsoft runtimes (Windows components)

Installed into a bottle only when the user chooses one, from Microsoft's own servers: Visual C++ Redistributables 2015–2022, 2013 and 2010, the .NET 8 Desktop Runtime, and the D3DX and D3DCompiler libraries of the DirectX End-User Runtime (June 2010). They are Microsoft's software under Microsoft's licence terms, which their installers and packages carry; Portnaut does not include or redistribute them. Because Portnaut runs the installers silently, it asks the user to accept Microsoft's terms before installing. The fixed-version files are checked against the SHA-256 hashes winetricks pins (https://github.com/Winetricks/winetricks). The approach, including which DLLs Wine should prefer and copying only D3DX from the DirectX package, follows winetricks (LGPL-2.1-or-later); no winetricks code is used.

## Component updates

With **Check for Component Updates…**, Portnaut reads Highball's engine manifests (https://github.com/gauthierpiarrette/highball, `spike/engines/`) and the release lists of https://github.com/gauthierpiarrette/highball-engine, https://github.com/Sikarugir-App/Template and https://github.com/KhronosGroup/MoltenVK, and downloads only what the user chooses to install. Newer parts carry the licences described above: Wine (LGPL), DXMT (LGPL), the template's libraries (GStreamer LGPL, SDL zlib, MoltenVK Apache-2.0), DXVK and D9VK (zlib). Highball's MoltenVK build (https://github.com/gauthierpiarrette/highball/releases/tag/engine-components) is MoltenVK with Highball's patches, Apache-2.0. Newer templates may carry a newer D3DMetal, including Apple betas (template 1.0.24: D3DMetal 4.0 beta 3), under Apple's Game Porting Toolkit licence and installed unmodified. From every template, Portnaut keeps only the top-level libraries, GStreamer and the renderer folders; the Sikarugir SDK and wrapper stay out.
