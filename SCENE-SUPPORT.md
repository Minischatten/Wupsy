# Native scene support

Wupsy opens/imports native project folders containing scene.wss.json, or the manifest itself. Referenced images, scalar masks, vector fields and Flow regions must be present inside the project. Managed import copies the project without changing the source and validates the copy before library publication.

Supported image effects are **Flow, Ripple and Clouds**; **Rain and CursorTrail** are separate scene layers. Mixed/repeated ordered image effects are supported within [effect budgets](docs/effects/COMMON.md#ordered-stacks). See [scene format](WSS-SCENE-FORMAT.md) and [Trail](WSS-TRAIL.md).

Unknown types, including removed surfaceAdvection and waterSurface effects, are explicitly rejected on opening/import and in backup/recovery payloads. There is no normalization, replacement renderer or migration. Invalid projects fail rather than regenerate or fall back to an external parser.

Wallpaper Engine project.json/scene.json, PKG/TEX containers, shader/preset recognition and derived-project conversion are unsupported. Historical imported library records and derived backup representations are rejected. Native orphan recovery projects retain generic WSS validation and transaction protections.

Save, Save As, backup/restore, FPS and pause/resume remain available for supported projects. Technical independence does not clear third-party content rights; see [notices](THIRD-PARTY-NOTICES.md).
