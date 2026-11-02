# Vendored Syphon

Upstream: https://github.com/Syphon/Syphon-Framework at
`f4761677a45b8034a3c2069ec0f3d2553da81fba` (2026-09-21). BSD license —
`VendoredLICENSE.txt`, which binary distributions must reproduce.

Only the Metal server and Metal client are vendored (plus the messaging,
connection and directory code they use); the OpenGL half is left out. The
client ships for tests and QA tools, not for any app feature.

Files are upstream's, unchanged, except where marked `MXU:`:

- `SyphonServerRendererMetal.m` — compiles its two shaders from an inlined
  copy of `SyphonMetalShaders.metal`, once per device, instead of loading a
  `default.metallib` from the framework bundle (statically linked, there is
  none).
- `SyphonCFMessageReceiver.m`, `SyphonMetalServer.m` — `os_unfair_lock`
  instead of `@synchronized`. `@synchronized` is an implicit `@try`, which
  links in the ObjC exception personality, and compact unwind encodes only
  three per image — past that the link fails with "Too many personality
  routines". Package.swift compiles the
  target with `-fno-objc-exceptions`, so ARC emits no landing pads either and
  any `@try`/`@synchronized` fails to compile.
- `SyphonPrivate.h` — imports Cocoa (upstream's prefix header did).
- `include/module.modulemap` — replaces upstream's framework module map
  (Metal headers only).

Upstream's prefix header only defines `SYPHONLOG`, a debug log; Package.swift
defines it empty.
