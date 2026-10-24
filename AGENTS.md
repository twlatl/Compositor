# Notes for AI agents

Pixegen is a macOS image editor for compositing and photo work, written in Swift (SwiftUI and AppKit, with some C for pixel work).

## Designing or editing a Pixegen project

If you've been asked to make or change an image in a `.pbox` project, you don't need the app's source code. Read [docs/writing-pbox-files.md](docs/writing-pbox-files.md): it covers the file format, the rules that make a project load, and how to write it safely while it's open, so the person can watch the canvas update as you work.

## Working on the app itself

- Build: open `Pixegen.xcodeproj` and run the **Pixegen** scheme, or `xcodebuild -project Pixegen.xcodeproj -scheme Pixegen -destination 'platform=macOS' build`.
- Tests: the `PixegenTests` target (`xcodebuild ... test -only-testing:PixegenTests`). CI runs these on every push.
- Match the surrounding code: its naming, its comment style and density.
- American spelling in code, comments and UI ("color", not "colour").
- The project file format is described in [docs/project-format.md](docs/project-format.md). A change to what's saved means a format version bump there and in `ProjectManifest.current`.
