# Polywog

Polywog is a Luau-first game engine. This is the playground demo build — a
self-contained binary you can run directly. The release version is shown by the
download's filename and the release tag.

## Running

- **Linux:** run `./playground` from inside this folder.
- **Windows:** run `playground.exe` from inside this folder.

Launch it from within the extracted folder so it can find `assets/` and the
Luau scripts next to the binary.

## What the demo does

A small facility whose breakers trip. Four devices, two lamps and two fans, sit
on two circuits; the sub circuit is fed from the main, so load flows upstream.
Switch on one machine too many and everything the tripped breaker feeds goes
dark, and nothing in the code says that should happen: each device declares what
it wants to draw, each breaker declares what it can supply, and the rest falls
out.

Drag to orbit, scroll to zoom, press `E` for the overlay.

The scripts are the point. `assets/scripts/main.luau` opens with a walkthrough;
from there, `power/Circuit.luau` is the file to read first. The demo is built on
`@polywog/app` for the window and the frame's stages, `@polywog/world/3d` for
the scene, meshes and lighting, and `@polywog/ui/screen` with `@polywog/ui/text`
for layout, pointer input, the render walk and typed text, all of it over the
`@polywog/binder` node tree and `@polywog/reactive` state.

`assets/scripts/test.luau` is not part of the demo; it is a headless self-check
that opens no window. Run it with `POLYWOG_PLAYGROUND_TEST=1 ./playground`.

## Writing Luau

The playground runs the Luau scripts shipped alongside the binary. Engine APIs
are exposed under `@polywog/...` modules. Open this folder in an editor with
luau-lsp — the bundled `.vscode/settings.json` wires up the engine types and
the new Luau type solver — for full autocomplete and type-checking.

The type stubs under `types/` are written the first time the binary runs, so run
it once before expecting autocomplete.

## Documentation

Open [`docs/index.html`](docs/index.html) in your web browser (Chromium,
Firefox, etc.) for the full API reference. No internet connection or local
server is needed — just open the file.

`docs/`, the `types/` stubs and the version stamped into `LICENSE` are all
produced when a release is packaged, so none of them is present in the source
repository.

## License

This is a proprietary build. Please do not redistribute it directly — see
[`LICENSE`](LICENSE). To get your own copy of the engine, join our Discord:

    https://discord.gg/FryZABrsDQ
