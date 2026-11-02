# Removing SwiftUI from the macOS application

This is a source audit and migration proposal, not an implemented rewrite. The inventory is pinned to `3eed77da5`, before the concurrent native-input performance changes. Counts come from tracked Swift files at that commit, including comments and blank lines. No migration build, performance comparison, or cross-version qualification was run for this document.

Ghostty already uses AppKit for application startup, window controllers, native tabs, terminal input, and the terminal surface. Removing SwiftUI means replacing the view composition around those components and untangling shared state and convenience types. It does **not** require replacing the terminal engine or GPU renderer.

For one engineer experienced with AppKit and terminal input, estimate **4–7 engineer-weeks for the main terminal/window composition** and **10–16 engineer-weeks for complete removal with current feature parity and regression qualification**. These are planning estimates, not measured delivery rates. The latter includes the former. Parallel implementation of secondary dialogs can help, but focus, ownership, and window integration remain a shared critical path.

## Inventory

| Scope | Swift files | Physical lines | Files importing SwiftUI | Lines in those files |
| --- | ---: | ---: | ---: | ---: |
| Production `macos/Sources` | 167 | 35,047 | 57 | 22,647 |
| Unit tests `macos/Tests` | 28 | 3,883 | 5 | 591 |
| UI tests `macos/GhosttyUITests` | 8 | 907 | 0 | 0 |
| Total | 203 | 39,837 | 62 | 23,238 |

The 22,647-line figure is **not the amount to rewrite**. It includes large AppKit controllers, the existing `NSTextInputClient`, and C API adapters with a small number of SwiftUI dependencies. For example, the 2,554-line `SurfaceView_AppKit.swift` is the native terminal view, despite its SwiftUI import.

Production also contains 11 files directly importing Combine, 8 files referencing `NSHostingView`, 6 files containing an `NSViewRepresentable` boundary, and 25 files referencing `ObservableObject` or its common property wrappers. These categories overlap. Taking their union with direct SwiftUI imports yields 60 production files; the three additional files are `AboutViewModel.swift`, `SecureInput.swift`, and `SplitTree.swift`. There are no `@Observable` uses in this baseline. Ten XIBs already provide AppKit menus/windows; they do not need conversion merely to remove SwiftUI.

| Area | SwiftUI-importing files / lines in them | What changes |
| --- | ---: | --- |
| App lifecycle | 1 / 1,443 | Remove observation conformance/import; preserve the AppKit delegate and main menu. |
| Terminal windows, tabs, Quick Terminal | 9 / 6,266 | Replace hosted content, small titlebar/accessory views, and glass wrapper. Preserve native windows, tab groups, restoration, fullscreen, and Quick Terminal behavior. |
| Split composition | 3 / 564 | Replace recursive views, divider gestures, drop-zone views, and accessibility bindings. Preserve `SplitTree`. |
| Surface composition and inspector | 9 / 5,307 | Replace pane overlays, search, focus/environment propagation, and representables. Preserve the native surface, scroll view, inspector renderer, and drag source. |
| Command palette | 2 / 729 | AppKit search field/list/selection, keyboard handling, responder restoration, and appearance. Preserve command enumeration/filtering logic. |
| About, clipboard confirmation, settings/errors | 8 / 601 | Replace hosted dialog bodies with AppKit controls. |
| Updates | 5 / 1,071 | Replace badge, pill, popovers, alert accessory, and UI observation. Preserve Sparkle and its update state machine. |
| Custom app icon wrappers | 2 / 34 | Remove SwiftUI preview/image helpers; preserve AppKit image generation and dock plug-in. |
| Secure-input overlay | 1 / 82 | Replace the overlay; preserve secure-input acquisition/release logic. |
| Shared Ghostty models/input adapters | 7 / 5,631 | Remove SwiftUI colors, shortcuts, namespace aliases, and observation coupling. Preserve the core bridge. |
| Helpers | 9 / 723 | Replace or delete SwiftUI extensions, backports, hosting wrappers, and generic Metal wrapper. Preserve native helpers. |
| App Intents | 1 / 196 | Replace SwiftUI screenshot rendering and, if removing Combine, publisher-based title/PWD waits. |

Settings is not a large preferences application today: `SettingsView.swift` is a 31-line “Coming Soon” placeholder. The other 105 lines in that folder implement configuration-error display. A new full preferences UI would be additional product work, outside this estimate.

## Existing boundaries to keep

The application starts with [`NSApplicationMain`](../macos/Sources/App/main.swift#L33). [`AppDelegate`](../macos/Sources/App/AppDelegate.swift#L8) owns the app instance, menu actions, global undo, Quick Terminal, and update controller. There is no SwiftUI `App`/`WindowGroup` lifecycle to replace.

[`BaseTerminalController`](../macos/Sources/Features/Terminal/BaseTerminalController.swift#L29) is already an `NSWindowController` and owns the focused surface and split tree. [`TerminalController`](../macos/Sources/Features/Terminal/TerminalController.swift#L1116) and [`QuickTerminalController`](../macos/Sources/Features/QuickTerminal/QuickTerminalController.swift#L140) install the same hosted `TerminalView`. That construction boundary is the best point to substitute an AppKit root container without rewriting window management.

The current display hierarchy is:

```text
AppDelegate / Ghostty.App
  BaseTerminalController -> TerminalController or QuickTerminalController
    NSWindow / TerminalViewContainer
      NSHostingView<TerminalView>
        TerminalSplitTreeView / SplitView
          InspectableSurface / SurfaceWrapper
            SurfaceRepresentable
              NativeCommandSurfaceHost or SurfaceScrollView  [AppKit]
                Ghostty.SurfaceView                          [AppKit]
                  core Metal renderer                        [Zig]
            InspectorView                                    [MTKView]
```

[`SurfaceRepresentable`](../macos/Sources/Ghostty/Surface%20View/SurfaceView.swift#L544) already returns the AppKit `NativeCommandSurfaceHost` for native-input sessions. All five Swift files in the baseline `Features/Command Input` folder are SwiftUI-free: the session, composer, text view, command layout, and surface host can be reused.

[`SurfaceView_AppKit.swift`](../macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift#L10) implements keyboard/mouse handling, terminal lifetime, `NSTextInputClient`, IME marked text, selection, drag/drop, and accessibility. [`SurfaceScrollView`](../macos/Sources/Ghostty/Surface%20View/SurfaceScrollView.swift#L15) already implements the native scrollbar/viewport bridge. Keep both. Their observation and SwiftUI type dependencies still need removal or isolation.

[`SplitTree`](../macos/Sources/Features/Splits/SplitTree.swift#L5) is a 1,429-line immutable model over native views, with serialization, spatial navigation, operations, and structural identity. Keep its algorithms and existing tests. Only its Combine aggregation extension is coupled to observable surface properties.

## The difficult parts

### Focus and surface identity

[`TerminalView`](../macos/Sources/Features/Terminal/TerminalView.swift#L41) receives focused surface, PWD, and cell size through `@FocusedValue`, while [`SurfaceWrapper`](../macos/Sources/Ghostty/Surface%20View/SurfaceView.swift#L7) publishes them through SwiftUI focus/environment values. Search and inspector add their own focus state. Removing these wrappers requires explicit callbacks into the existing window controller and a single authoritative focused-surface identity.

Do not recreate a surface or PTY when a split is rearranged. The current split root deliberately uses [`structuralIdentity`](../macos/Sources/Features/Splits/TerminalSplitTreeView.swift#L40) to control SwiftUI reuse. An AppKit replacement must instead reconcile existing leaf views by stable surface ID, preserve their sessions and editor drafts, and deliberately update attachment, size, responder, and core focus. Undo can retain live PTYs; closing and undoing a split must preserve that behavior.

### Split layout, drag/drop, and windows

The existing [`SplitView`](../macos/Sources/Features/Splits/SplitView.swift#L8) implements a one-point divider with a larger hit area, minimum sizes, ratio changes, double-click equalization, and accessible adjustment. A custom AppKit split container can use the same ratios/geometry; `NSSplitView` is also a candidate if its behavior is verified against these requirements. Choosing it does not eliminate reconciliation, zoom, drag/drop, or accessibility work.

The drag source is already a native [`NSDraggingSource`](../macos/Sources/Ghostty/Surface%20View/SurfaceDragSource.swift#L82). Reuse it while replacing SwiftUI bindings/preferences and the destination drop zones. Keep native `NSWindow` tabs and the existing tab-group close/restoration logic. Tahoe titlebar code already contains version-specific AppKit tab-bar workarounds; replacing its small hosted title does not remove that risk.

### State ownership beyond the views

The observation graph reaches [`Ghostty.App`](../macos/Sources/Ghostty/Ghostty.App.swift#L14), [`Ghostty.Config`](../macos/Sources/Ghostty/Ghostty.Config.swift#L6), [`OSSurfaceView`](../macos/Sources/Ghostty/Surface%20View/OSSurfaceView.swift#L6), native surface/controller classes, secure input, and the update model. Publishers also perform real non-rendering work: title/appearance updates, clipboard confirmation, bell aggregation, search input, accessibility notifications, and App Intents metadata waits.

Combine is a separate framework; an AppKit UI can retain it. For a final design consistent with the new native-input code, prefer explicit main-actor callbacks/delegates for UI state, with observer tokens where multiple consumers need events. A temporary Combine adapter can make staged conversion safer. Replacing `@Published` with stored properties alone would silently break the remaining subscribers. Preserve initial-value delivery, cancellation, per-pane identity, and main-actor delivery when migrating them. Avoid adding periodic polling as an observation replacement.

SwiftUI also leaks through value types: [`Ghostty.Action.ColorChange`](../macos/Sources/Ghostty/Ghostty.Action.swift#L9), config colors, `KeyboardShortcut`/`KeyEquivalent`/`EventModifiers`, and the shortcut display helpers. Use AppKit colors and a small app-owned shortcut value carrying the existing key/modifier/physical-key semantics. Keep keyboard-layout behavior and shortcut tests. Replace `SwiftUI.Notification` qualifications with Foundation equivalents. `GhosttyPackage.swift` largely imports SwiftUI transitively and does not represent a whole UI rewrite.

[`TerminalEntity`](../macos/Sources/Features/App%20Intents/Entities/TerminalEntity.swift#L68) uses `ImageRenderer` for screenshots despite an existing [`NSImage` screenshot helper](../macos/Sources/Helpers/Extensions/NSView+Extension.swift#L27). Reuse the native helper, then verify captures still contain the layer-hosted terminal. App Intents and AppleScript behavior should survive the migration.

### Secondary UI and visual compatibility

Replace search with a native text field and navigation controls; palette rows with native list/table views; badges/popovers with AppKit controls; static borders/highlights with view drawing or layers. Preserve first-responder restoration, native command-editor focus, disabled/readonly states, VoiceOver labels, find-pasteboard synchronization, and keyboard selection.

`TerminalViewContainer` hosts an additional SwiftUI [`glass background`](../macos/Sources/Features/Terminal/TerminalViewContainer.swift#L108) on Tahoe. Plan a separate visual-parity spike using version-gated AppKit effect views and the existing older-system fallback. Do not promise identical glass rendering before checking supported OS versions. About already wraps an `NSVisualEffectView`, which can be used directly.

The inspector's content is already [`MTKView` plus `NSTextInputClient`](../macos/Sources/Ghostty/Surface%20View/InspectorView.swift#L94), backed by core ImGui/Metal. Replace its SwiftUI show/hide, focus, and split wrapper. Rewriting the inspector controls themselves as AppKit would be extra scope; removing SwiftUI does not require it.

## Where Metal belongs

The terminal already uses [`GenericRenderer(Metal)`](../src/renderer/Metal.zig#L15), Metal command queues/textures, and an [`IOSurfaceLayer` attached to the native view](../src/renderer/Metal.zig#L93). The inspector already has its own Metal path. No renderer migration is needed to make the application SwiftUI-free.

Keep menus, dialogs, search, tabs, and the command editor as AppKit controls. `NSTextView` provides the selection, editing, undo, text services, and IME behavior this fork needs. Custom Metal controls would require reimplementing those interactions and accessibility. Use view/layer drawing for small decorations; introduce additional GPU drawing only when profiling identifies a concrete bottleneck.

SwiftUI removal is not itself evidence of lower CPU or input latency. The current native-input polling, filesystem reads, geometry queries, and layout work are independent costs and should be measured/fixed separately. Compare the same workload and build configuration before claiming a migration speedup.

## Phased implementation and estimated effort

Assumptions: retain existing functionality and supported macOS versions, reuse core rendering/window logic, no new full settings UI, no custom GPU widget framework, and one experienced engineer with review/testing support. Ranges include ordinary integration fixes. Unfamiliarity with the code, new design requirements, or difficult OS-specific bugs can extend them.

| Phase | Deliverable and gate | Estimate |
| --- | --- | ---: |
| 1. Establish AppKit boundaries | Preserve controller ownership; define callbacks, shortcut/color values, and view identity rules. Add focused regression coverage for migration-sensitive behavior and capture a performance baseline. | 1–2 weeks |
| 2. Replace terminal composition | AppKit root, stable split containers, pane overlays, search/inspector wrappers, explicit focus routing. Both ordinary and native-input sessions work in regular/Quick Terminal windows; resize, zoom, moves, and close/undo retain PTYs. | 3–5 weeks |
| 3. Replace remaining hosted UI | Palette, title/tab accessories, glass, clipboard/config/About dialogs, update presentation, helpers and App Intents screenshot path. Preserve update driver and existing window management. | 3–4 weeks |
| 4. Finish decoupling and qualify | Remove obsolete SwiftUI observation/types/imports/previews, adapt tests, audit targets/linkage, qualify OS/focus/accessibility/IME/window behavior, and remeasure performance. | 3–5 weeks |
| **Total** | Complete source-level removal with feature parity | **10–16 engineer-weeks** |

Phases 1–2 form the 4–7-week main-composition milestone. That milestone is useful but **is not complete removal**: secondary windows, palettes, titlebar accessories, and helpers can still load SwiftUI. A narrower prototype that drops features can be quicker but is not the parity estimate above.

Use one owner for the root container/focus protocol. Secondary dialogs can migrate independently once shared types settle. Keep the new AppKit implementation switchable during development, then remove the old path when its replacement passes the gate. Do not mix the renderer or shell transport rewrite into this project.

This creates an ongoing fork-maintenance cost: upstream macOS UI fixes will need translation into the new AppKit composition, even when core changes remain straightforward to merge. Preserve controller/core boundaries and keep the new composition in focused files to reduce that burden. The estimate covers the migration, not future upstream reconciliation.

## Completion criteria

- No SwiftUI imports, qualified SwiftUI symbols, hosting/representable wrappers, SwiftUI view types, or previews remain in tracked macOS production or test source. Check indirect helpers and target membership, not just files named `*View`.
- Every window/controller path constructs AppKit content, including Quick Terminal, dialogs, tabs/titlebars, updates, error states, inspector host, and native/ordinary terminal panes.
- Observation migration preserves configuration reloads, title/PWD changes, search, clipboard confirmation, secure-input activation/deactivation, bell/progress notifications, accessibility updates, and App Intents waits. Combine can remain temporarily, but no remaining subscriber may depend on a removed publisher.
- Run existing relevant unit/UI tests and add coverage for changed ownership/layout behavior. Manually qualify multiwindow/split focus, tab detach/reattach, restoration/undo, multiple displays/scales, fullscreen, Quick Terminal, search/palette/inspector focus, dragging, themes/transparency/glass, and update presentation across supported OS versions.
- Verify multiline native editing, paste/selection/undo, foreground `read` and TUI handoff, alternate-screen restoration, background-pane completion, physical IME input, and VoiceOver. Current prototype checks do not substitute for migration qualification.
- Measure idle/hidden/background CPU, layout counts, memory, input latency, resize/scroll throughput, and many-pane behavior against a matching release baseline. Report measured changes separately from architectural expectations.
- If “no SwiftUI” includes binary loading, inspect linked/loaded frameworks in the built application and plug-ins. Removing our imports proves source-level removal only; Apple/system or external dependencies require a separate linkage/runtime check.

## Complete direct-import file list

Paths below are relative to `macos/Sources`; counts are from the pinned commit. This list includes mixed AppKit/SwiftUI files and preview-only helpers.

```text
App/AppDelegate.swift
Features/About/AboutController.swift
Features/About/AboutView.swift
Features/About/CyclingIconView.swift
Features/App Intents/Entities/TerminalEntity.swift
Features/ClipboardConfirmation/ClipboardConfirmationController.swift
Features/ClipboardConfirmation/ClipboardConfirmationView.swift
Features/Command Palette/CommandPalette.swift
Features/Command Palette/TerminalCommandPalette.swift
Features/Custom App Icon/ColorizedGhosttyIconImage.swift
Features/Custom App Icon/ColorizedGhosttyIconView.swift
Features/QuickTerminal/QuickTerminalController.swift
Features/Secure Input/SecureInputOverlay.swift
Features/Settings/ConfigurationErrorsController.swift
Features/Settings/ConfigurationErrorsView.swift
Features/Settings/SettingsView.swift
Features/Splits/SplitView.Divider.swift
Features/Splits/SplitView.swift
Features/Splits/TerminalSplitTreeView.swift
Features/Terminal/BaseTerminalController.swift
Features/Terminal/ErrorView.swift
Features/Terminal/TerminalController.swift
Features/Terminal/TerminalTabColor.swift
Features/Terminal/TerminalView.swift
Features/Terminal/TerminalViewContainer.swift
Features/Terminal/Window Styles/TerminalWindow.swift
Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift
Features/Update/UpdateBadge.swift
Features/Update/UpdateController.swift
Features/Update/UpdatePill.swift
Features/Update/UpdatePopoverView.swift
Features/Update/UpdateViewModel.swift
Ghostty/Ghostty.Action.swift
Ghostty/Ghostty.App.swift
Ghostty/Ghostty.ChildExitedMessage.swift
Ghostty/Ghostty.Config.swift
Ghostty/Ghostty.Input.swift
Ghostty/Ghostty.MenuShortcutManager.swift
Ghostty/GhosttyPackage.swift
Ghostty/Surface View/ChildExitedMessageBar.swift
Ghostty/Surface View/InspectorView.swift
Ghostty/Surface View/OSSurfaceView.swift
Ghostty/Surface View/SurfaceDragSource.swift
Ghostty/Surface View/SurfaceGrabHandle.swift
Ghostty/Surface View/SurfaceProgressBar.swift
Ghostty/Surface View/SurfaceScrollView.swift
Ghostty/Surface View/SurfaceView.swift
Ghostty/Surface View/SurfaceView_AppKit.swift
Helpers/Backport.swift
Helpers/Cursor.swift
Helpers/Extensions/EventModifiers+Extension.swift
Helpers/Extensions/KeyboardShortcut+Extension.swift
Helpers/Extensions/NSView+Extension.swift
Helpers/Extensions/View+Extension.swift
Helpers/MetalView.swift
Helpers/NonDraggableHostingView.swift
Helpers/URLHoverBanner.swift
```

The five unit-test imports are `CommandPaletteTests.swift`, `Ghostty/ConfigTests.swift`, `Ghostty/KeyEventSynthesizeTests.swift`, `Terminal/TerminalViewContainerTests.swift`, and `Update/UpdateViewModelTests.swift`. Preserve their behavioral checks while replacing SwiftUI test values/fixtures. None of the eight UI-test files directly imports SwiftUI, but their interaction expectations remain relevant.

To reproduce the direct-import counts without including concurrent worktree edits:

```sh
uv run --no-project python - <<'PY'
import re
import subprocess

commit = '3eed77da5'
paths = subprocess.check_output(
    ['git', 'ls-tree', '-r', '--name-only', commit, 'macos'], text=True
).splitlines()
rows = []
for path in paths:
    if not path.endswith('.swift'):
        continue
    source = subprocess.check_output(['git', 'show', f'{commit}:{path}'], text=True)
    rows.append((path, len(source.splitlines()), bool(re.search(r'^import SwiftUI\b', source, re.M))))
for prefix in ('macos/Sources/', 'macos/Tests/', 'macos/GhosttyUITests/', 'macos/'):
    group = [r for r in rows if r[0].startswith(prefix)]
    print(prefix, 'files/lines/importing files/importing-file lines:',
          len(group), sum(r[1] for r in group),
          sum(r[2] for r in group), sum(r[1] for r in group if r[2]))
PY
```
