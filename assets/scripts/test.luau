--!strict
--- NOT THE DEMO — `main.luau` is. This file is a headless self-check that runs in place
--- of it, opens no window, prints a line or two and exits. If you opened
--- `assets/scripts/` looking for the thing you just ran, read `main.luau`; its header is
--- the walkthrough.
---
--- Headless behaviour check: tripping a breaker actually darkens the cubes.
---
--- Run it with `POLYWOG_PLAYGROUND_TEST=1 ./playground` from the directory holding the
--- binary.
---
--- This asserts the demo's central claim against real GPU output rather than against
--- the reactive graph. Asserting `tripped == true` would only prove the power model
--- agrees with itself; `readPixels` proves the *frame* changed, which is the thing a
--- reader is actually shown.
---
--- THE HARNESS IS `app.headless`, and what it buys is not brevity. The tree below is
--- structurally identical to `main.luau`'s — a provider node binding `Target` and
--- `Frame`, a scene under it, a UI layer beside the scene — and the only difference
--- between the two files is who calls `step`: a window's `onUpdate` there, the loop
--- here. So this checks the arrangement the demo actually ships rather than a second
--- one assembled by hand, which would be free to drift from it.
---
--- Deliberately NOT a per-pixel comparison. Total luminance is one number that
--- survives anyone moving a cube, changing a tint, or reframing the camera — all of
--- which would break a golden image while leaving the claim true.

local assets = require("@polywog/assets")
local scene3d = require("@polywog/scene3d")
local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local layout = require("@polywog/ui/layout")
local render = require("@polywog/ui/render")
local appmod = require("@polywog/app")
local world3d = require("@polywog/world/3d")
local screenmod = require("@polywog/ui/screen")
local uitext = require("@polywog/ui/text")
local Scope = require("@polywog/scope")

local Circuit = require("./power/Circuit")
local Device = require("./power/Device")
local Facility = require("./power/Facility")
local Panel = require("./ui/Panel")

local WIDTH = 256
local HEIGHT = 256

local scope = Scope()

--- Called ONCE and kept. `app.headless(config)` is a class FACTORY — it returns a fresh
--- class per call — so calling it again inside the `binder.use` would name a different
--- class, build a second context on this node and trip the provider's one-per-node
--- assert.
local Headless = appmod.headless({ width = WIDTH, height = HEIGHT })

--- `hostNode` is the root, as `windowNode` is in `main.luau`: the provider binds
--- `Target` and `Frame` on its own node, and everything on or under it draws there.
local hostNode = binder.node.create(scope)
local host = binder.use(scope, hostNode, Headless)

local target = host.target
local frame = host.frame
local gfx = target.gfx

local sceneNode = binder.node.create(hostNode)
local playerNode = binder.node.create(sceneNode)

local facility = Facility(scope, sceneNode)

-- ── The scene, assembled exactly as `main.luau` assembles it ─────────────────────

local scene = binder.use(scope, sceneNode, world3d.Scene3D)
local camera = binder.use(scope, playerNode, world3d.Camera3D)

camera.configure({ target = vector.create(0, 0.5, 0) })

local lighting = binder.use(scope, sceneNode, world3d.Lighting3D)
lighting.configure({
	position = vector.create(4, 8, 6),
	color = vector.create(1, 0.97, 0.9),
	ambient = 0.16,
	intensity = 0.8,
})

scene.configure({ camera = camera, lighting = lighting })

local cube = scene3d.loadMeshObj(gfx, assets.loadAsync("meshes/cube.obj"):bytes())

for _, entry in facility.devices do
	local device = binder.use(scope, entry.node, Device)
	local mesh = binder.use(scope, entry.node, world3d.Mesh3D)

	mesh.configure({ mesh = cube })

	--- THE THING THIS FILE MEASURES. `brightness` scales the diffuse-and-ambient term
	--- only, so an unpowered cube still catches a highlight — which is why the
	--- luminance assertion below is a comparison rather than a test for black.
	mesh.material3d.configure({
		color = device.tint,
		brightness = reactive.computed(scope, function(use: reactive.Use): number
			return if use(device.lit) then 1 else 0.18
		end),
	})
end

-- ── Driving the frame ────────────────────────────────────────────────────────────

--- `Frame.step` runs sync, then the write batch, then the render stages in band order.
--- What it does NOT do is present: `Frame` holds no graphics dependency, which is what
--- keeps its own suite runnable with no adapter, so presenting is the provider's job —
--- and `app.headless` has no event loop to do it from. Hence the explicit call here: a
--- headless sequence that renders twice without presenting raises on its second
--- clearing pass.
local elapsed = 0

local function stepFrame()
	elapsed += 1 / 60
	frame.step(1 / 60, elapsed)
	gfx:present()
end

--- Sums the RGB channels over the whole frame.
local function renderLuminance(): number
	stepFrame()

	local pixels = gfx:readPixels()
	local total = 0

	for offset = 0, WIDTH * HEIGHT * 4 - 4, 4 do
		total += buffer.readu8(pixels, offset)
			+ buffer.readu8(pixels, offset + 1)
			+ buffer.readu8(pixels, offset + 2)
	end

	return total
end

--- Collect the two lamps by name. Both sit on the main breaker, and together they
--- exceed its capacity — which is the whole scenario.
local lamps: { Device.Device } = {}
for _, entry in facility.devices do
	if string.find(entry.name, "lamp") ~= nil then
		table.insert(lamps, binder.use(scope, entry.node, Device))
	end
end

assert(#lamps == 2, `expected 2 lamps in the facility, found {#lamps}`)

local main = binder.use(scope, facility.circuits[1].node, Circuit)

-- ── Phase 1: overload the main breaker ───────────────────────────────────────────

reactive.batch(function()
	for _, lamp in lamps do
		reactive.set(lamp.switch, true)
	end
end)

assert(
	reactive.peek(main.tripped),
	`main breaker did not trip: load {reactive.peek(main.load)} W on capacity {reactive.peek(main.capacity)} W`
)

local trippedLuminance = renderLuminance()

-- ── Phase 2: shed one lamp, then reset ───────────────────────────────────────────
--
-- Order matters and the test would be wrong the other way round. `reset` re-checks the
-- overload condition, so resetting while still overloaded trips straight back — which
-- is the behaviour the demo teaches. Switching a lamp off FIRST is what makes the reset
-- hold, and doing it in one batch keeps the assertion below from racing a flush.

reactive.batch(function()
	reactive.set(lamps[1].switch, false)
end)

main.reset()

assert(
	not reactive.peek(main.tripped),
	"main breaker stayed tripped after shedding a lamp and resetting"
)
assert(
	reactive.peek(lamps[2].lit),
	"the remaining lamp is not lit on a healthy circuit"
)

local litLuminance = renderLuminance()

print(`tripped luminance: {trippedLuminance}`)
print(`lit luminance:     {litLuminance}`)

--- The claim, and it routes through `Material3D.brightness` reaching the GPU. A
--- `brightness` the shader ignored would leave these two numbers EQUAL, which is what
--- makes a comparison the right predicate: `dim > 0` would hold for a shader that never
--- read the field at all.
assert(
	litLuminance > trippedLuminance,
	`expected a brighter frame once powered, got {litLuminance} <= {trippedLuminance}`
)

-- ── Phase 3: the sub-circuit, and that load flows upstream ───────────────────────
--
-- Two claims the panel makes that the luminance check above cannot see.

local sub = binder.use(scope, facility.circuits[2].node, Circuit)

local fans: { Device.Device } = {}
for _, entry in facility.devices do
	if string.find(entry.name, "fan") ~= nil then
		table.insert(fans, binder.use(scope, entry.node, Device))
	end
end

assert(#fans == 2, `expected 2 fans on the sub circuit, found {#fans}`)

--- Start from everything off so the two circuits are read in isolation.
reactive.batch(function()
	for _, lamp in lamps do
		reactive.set(lamp.switch, false)
	end
end)

main.reset()

assert(not reactive.peek(main.tripped), "main would not clear with every device off")

reactive.batch(function()
	for _, fan in fans do
		reactive.set(fan.switch, true)
	end
end)

local fanLoad = reactive.peek(sub.load)

--- The sub must be trippable at all: a breaker whose devices can never exceed its
--- capacity has a reset button that can never do anything.
assert(
	reactive.peek(sub.tripped),
	`sub breaker did not trip: load {fanLoad} W on capacity {reactive.peek(sub.capacity)} W`
)

--- LOAD FLOWS UPSTREAM. The main is supplying the sub, so the fans' draw is the main's
--- load too — even though no fan is a contributor to the main directly. This is the
--- assertion that fails if `feedFrom` only wires power downward.
assert(
	reactive.peek(main.load) == fanLoad,
	`main should carry the sub's whole draw: main {reactive.peek(main.load)} W vs sub {fanLoad} W`
)

--- And the main must NOT have tripped with it: the numbers are tuned so overloading
--- the sub leaves the main inside its own capacity, so each scenario trips exactly one
--- breaker and stays legible.
assert(
	not reactive.peek(main.tripped),
	`main tripped alongside the sub: {reactive.peek(main.load)} W on {reactive.peek(main.capacity)} W`
)

print(`sub load: {fanLoad} W, seen by main as {reactive.peek(main.load)} W`)

-- ── Phase 4: the panel's text runs still collapse ────────────────────────────────
--
-- `ui/Panel.luau`'s CARD_GAP is load-bearing: the render walk merges a text run with the
-- quads after it only when those quads can paint no pixel the text can, judged on whole
-- pixels. A label's bottom edge is fractional, so with no gap the next quad shares its
-- last pixel row, and the panel silently costs four more render runs per frame with no
-- visual change anyone would notice. `render.debug.runsMerged` makes that enforceable,
-- so it is asserted here rather than left as a comment asking to be obeyed.

--- BUILT HERE rather than at the top, and the placement is load-bearing. `Screen`
--- registers its render stage the moment it is constructed, so a UI layer created
--- before Phase 1 would composite the panel over every luminance frame — and the
--- panel's own bars and labels change colour with breaker state, which is precisely
--- the signal those phases measure. Phases 1-3 render the 3D scene alone.
local uiNode = binder.node.create(hostNode)
local panelNode = binder.node.create(uiNode)

--- On `hostNode`, beside the `Target` it renders for, as `main.luau` puts its own on
--- `windowNode`.
local fonts = binder.use(scope, hostNode, uitext.Fonts)

--- No `getEvents`. Nil means this Screen receives no pointer input, which is the honest
--- answer headlessly: there is no window, so `app.Window`'s input pump never runs and
--- there is nothing to poll. What is being checked here is the walk, not dispatch.
local screen = binder.use(scope, uiNode, screenmod.Screen)

screen.configure({
	--- Doing the real prepare-and-render rather than a no-op is deliberate — the run
	--- count comes out of `walk` either way, but a no-op would leave the demo's text
	--- path unexercised by the only thing that runs it without a display. That is what
	--- `fonts.drawText` does, and it carries the `render.TextArea`-to-`prepare` cast so
	--- that neither this file nor `main.luau` has to.
	drawText = fonts.drawText,
})

--- `Screen` puts a filled `layout.Box` on this node itself, so only the row is added
--- here. `binder.use` is idempotent, so this Flex lands on that same Box.
binder.use(scope, uiNode, layout.Flex).configure({ direction = "row" })

local panel = binder.use(scope, panelNode, Panel)
panel.showFacility(facility)

--- Read as a DELTA. `runsMerged` is cumulative across every renderer in the VM, so an
--- absolute value would pass for reasons having nothing to do with this frame.
local before = render.debug.runsMerged()

stepFrame()

local merged = render.debug.runsMerged() - before

--- `Screen` exposes the run COUNT rather than the frame: the `Frame` a walk returns is
--- invalidated by the next one, because the renderer's batch pool hands out the same
--- objects and resets them in place.
local runs = reactive.peek(screen.runs)

print(`panel runs: {runs}, merges this walk: {merged}`)

--- The RUN COUNT is the assertion, not the merge count, and the difference matters.
--- `merged > 0` passes as long as ANY merging happens anywhere, so zeroing `CARD_GAP`
--- takes the panel from 2 runs to 6 while `merged` still reads 5. Two boundaries feed
--- this — a card's heading to its bar, and its reset label to the next card — and a
--- weak predicate only needs one of them to hold.
---
--- Two is the floor for a frame containing both quads and text: one quad run, one text
--- run. Anything above it means a boundary stopped collapsing.
---
--- WHAT MAKES THIS MEANINGFUL IS THE PANEL'S LABELS. Runs split on KIND, not on
--- adjacency: `quadRun` keeps one batch open and every later quad appends to it, so N
--- disjoint filled panels are ONE run however far apart they sit, and only a text run
--- closes the batch. A panel that stopped carrying text would collapse to 1 run
--- unconditionally and this bound would hold for a reason that has nothing to do with
--- the gaps.
local FULLY_COLLAPSED = 2

assert(
	runs <= FULLY_COLLAPSED,
	`the panel's text runs stopped collapsing: {runs} runs, expected {FULLY_COLLAPSED} `
		.. `(merged={merged}) — see CARD_GAP in ui/Panel.luau`
)

--- Kept alongside, because the two say different things: the count above is what a
--- frame COSTS, this is whether collapsing is doing anything at all. A future engine
--- that stopped merging entirely but happened to emit few runs would pass the first.
assert(merged > 0, `runsMerged reported no merging at all (runs={runs})`)

print("PASS: breaker darkens the cubes; load flows upstream; the sub trips; the panel collapses")

scope.destroy()
