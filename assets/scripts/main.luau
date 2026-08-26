--!strict
--- The playground: a small facility whose breakers trip.
---
--- Switch on one machine too many and a whole room goes dark. Nothing in the code
--- says that. Each device declares what it wants to draw, each breaker declares
--- what it can supply, and the result falls out — which is the thing this demo
--- exists to show you.
---
--- TRY THIS FIRST. Switch both lamps on: together they ask for more than the main
--- breaker can supply, so it trips and every room goes dark. Click its reset — nothing
--- happens, because the circuit is still overloaded and it trips straight back. Switch
--- one lamp off, reset again, and the other comes back.
---
--- Now switch that last lamp off as well, so nothing at all is drawing, and then switch
--- both fans on. They are on their own breaker, so the SUB trips this time and only the
--- fans go dark. And watch the MAIN's bar while you do it: it climbs too, without the
--- main tripping, because the main is supplying the sub — so everything the sub draws is
--- load the main is carrying.
---
--- Shedding that lamp first is the whole reason this step reads cleanly, and it is worth
--- knowing what happens if you skip it. Leave a lamp on and the fans' draw lands on top
--- of it, which is more than the main can supply: the MAIN trips as well and the entire
--- facility goes dark, so you see nothing about the sub at all. That is not the demo
--- breaking — it is the same upstream rule the paragraph above is trying to show you,
--- firing at a moment when it drowns out the thing being demonstrated. `test.luau`'s
--- Phase 3 switches the lamps off for exactly this reason, so the two circuits can be
--- read in isolation.
---
--- Finally, watch a fan lose power to a breaker it is not even on. Switch one fan off and
--- reset the sub, so the other fan is running again and its own circuit is comfortably
--- inside its limit. Now switch both lamps on. That is more than the main can carry, so
--- the MAIN trips — and the fan goes dark with it, without anything having checked for
--- it, because the sub's breaker is fed from the main. Both lamps, not one: a single lamp
--- alongside a running fan lands exactly ON the main's capacity, and the trip test is a
--- strict overload, so exactly-at-capacity holds.
---
--- The watt and capacity figures all live in `power/Facility.luau`, so they are
--- deliberately not repeated here; this paragraph would go stale the moment you changed
--- one.
---
--- WHERE TO LOOK
---   power/Circuit.luau            why `tripped` is an effect while everything else is a
---                                 computed. Read this one first.
---   power/Facility.luau           the tree is ownership; circuits are a second graph laid
---                                 over it, so a breaker is a SIBLING of the rooms.
---   camera/OrbitController.luau   a driver that never names a camera, which is what makes
---                                 it interchangeable with `AutoPanController`. The effect
---                                 below is the whole of the swap.
---   power/Device.luau             the case AGAINST splitting, so the pattern above reads
---                                 as a judgement rather than as a rule.
---
--- WHAT THIS FILE DOES NOT CONTAIN, because that is the interesting half. There is no
--- window binder, no camera or transform type, no scene walk, no shader and no frame
--- callback. `@polywog/app`, `@polywog/world/3d` and `@polywog/ui/screen` own all of
--- it; what is left here is the ~25 lines that are about THIS demo rather than about
--- being an engine.
---
--- Controls: drag to orbit, scroll to zoom, `E` for the overlay.

local input = require("@polywog/input")
local future = require("@polywog/future")
local clock = require("@polywog/clock")
local assets = require("@polywog/assets")
local scene3d = require("@polywog/scene3d")
local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local layout = require("@polywog/ui/layout")
local animation = require("@polywog/animation")
local appmod = require("@polywog/app")
local world3d = require("@polywog/world/3d")
local screenmod = require("@polywog/ui/screen")
local uitext = require("@polywog/ui/text")
local Scope = require("@polywog/scope")

local OrbitController = require("./camera/OrbitController")
local AutoPanController = require("./camera/AutoPanController")
local Circuit = require("./power/Circuit")
local Device = require("./power/Device")
local Facility = require("./power/Facility")
local Panel = require("./ui/Panel")
local Overlay = require("./ui/Overlay")

local scope = Scope()

--- `root` holds only what is genuinely singular. Everything else is a node because
--- it is a THING, and each consumer receives the nodes it needs rather than
--- reaching for a global.
---
--- EVERYTHING SITS UNDER `windowNode`, and that is structural rather than tidy.
--- `app.Window` binds `app.Target` and `app.Frame` on its OWN node, and every
--- participant — `Scene3D`, `Mesh3D`, `Screen` — finds them with
--- `binder.observeAncestor`, which searches STRICTLY ABOVE itself. Make these
--- siblings of `windowNode` instead and nothing errors: the scene reports itself
--- an orphan through `frame.orphans`, the screen never renders, and the window
--- comes up blank.
local root = binder.node.create(scope)
local windowNode = binder.node.create(root)
local sceneNode = binder.node.create(windowNode)
--- Under `sceneNode` rather than beside it. `Scene3D.camera` is a REFERENCE rather
--- than a search, so the parenting is not required — but a camera living outside
--- the scene it films reads as an accident, and the controllers bind onto this node.
local playerNode = binder.node.create(sceneNode)
local uiNode = binder.node.create(windowNode)

--- `app.Window`'s construction yields (it waits for the OS window), and a binder
--- constructor may not — so it returns a `Future` and this is where we wait for it.
--- A script's top level is a coroutine, so `await` is legal here and nowhere inside
--- a frame stage.
local window = future.await(binder.use(scope, windowNode, appmod.Window))

--- Bound by the provider on its own node, which is why these are `get` rather than
--- `use`: asking for them with `use` would construct a second, seedless `Target`
--- and raise. Both land on `windowNode` — the same node `app.Window` is on — so
--- this is the accessor, not a guess.
local target = binder.get(windowNode, appmod.Target)
local frame = binder.get(windowNode, appmod.Frame)
assert(target ~= nil and frame ~= nil, "app.Window binds Target and Frame on its own node")

--- The scene's clear colour, owned by `Frame` because only the FIRST render stage
--- in band order clears and `Frame` is what knows which one that is.
reactive.set(frame.clearColor, vector.create(0.04, 0.045, 0.06, 1))

--- Text. `Fonts` owns the font system (all font memory) and a `Target`-derived text
--- renderer (the GPU glyph atlas), so both are created once rather than per frame —
--- and the renderer is rebuilt if the `Target` ever changes, which a hand-built one
--- here could not be.
---
--- ON `uiNode`, NOT on `windowNode`, and getting this wrong fails silently in both
--- directions. `binder.observeAncestor` searches STRICTLY ABOVE its own node — a
--- provider would otherwise always find itself — and `app.Window` binds `Target` and
--- `Frame` on `windowNode` ITSELF. So a `Fonts` on `windowNode` sees no `Target` at
--- all: `drawText` returns early every frame and every label simply stops appearing,
--- with no error. It would not even be counted, because with no `Frame` above it
--- either there is nowhere to report to, so `frame.orphans` stays zero.
---
--- One node down is what satisfies both ends at once: `uiNode` is a child of
--- `windowNode`, so the search upward reaches `Target` and `Frame`, and it is an
--- ancestor of every node the UI puts text on, so each `Text` searching upward
--- reaches this.
local fonts = binder.use(scope, uiNode, uitext.Fonts)

local facility = Facility(scope, sceneNode)

--- Resolved once, outside the computed below. `binder.use` returns the same binding
--- every time, but it is not free to re-ask: each call registers another release on
--- `scope` and bumps the binding's user count, so calling it inside a reactive body
--- leaks a registration per re-run — silently, and at whatever rate that body runs.
local circuits: { Circuit.Circuit } = {}
for _, entry in facility.circuits do
	table.insert(circuits, binder.use(scope, entry.node, Circuit))
end

--- The title is a `Value`, so it can simply FOLLOW a computed rather than being
--- assigned each frame. Nothing polls; it changes when a breaker changes.
reactive.bind(scope, window.title, reactive.computed(scope, function(use: reactive.Use): string
	local tripped = 0

	for _, circuit in circuits do
		if use(circuit.tripped) then
			tripped += 1
		end
	end

	if tripped == 0 then
		return "polywog playground — all circuits live"
	end

	return `polywog playground — {tripped} breaker(s) tripped`
end))

-- ── The 3D view ──────────────────────────────────────────────────────────────────

local scene = binder.use(scope, sceneNode, world3d.Scene3D)
local camera = binder.use(scope, playerNode, world3d.Camera3D)

--- `Camera3D` looks at the origin by default, and this demo's cubes sit at y = 0.5.
camera.configure({ target = vector.create(0, 0.5, 0) })

--- These four are written out rather than left to `Lighting3D`'s defaults, three of
--- which they happen to equal. A default that changed upstream would relight the scene
--- with nothing here to notice.
---
--- `specular` and `shininess` live on `Material3D` and are already what this demo
--- wants, so no device configures them.
local lighting = binder.use(scope, sceneNode, world3d.Lighting3D)
lighting.configure({
	position = vector.create(4, 8, 6),
	color = vector.create(1, 0.97, 0.9),
	ambient = 0.16,
	intensity = 0.8,
})

scene.configure({ camera = camera, lighting = lighting })

--- One cube, shared by every device. `Mesh3D` searches upward for its `Scene3D` and
--- attaches itself, so there is no membership list to keep and no draw loop here at
--- all — the scene owns a render stage at band 0 and a depth texture to go with it.
---
--- That depth attachment is why there is no back-to-front sort in this file, and no
--- precondition on the geometry to go with one: nothing here requires that every solid
--- be convex, or that no two of them intersect.
local cube = scene3d.loadMeshObj(target.gfx, assets.loadAsync("meshes/cube.obj"):bytes())

for _, entry in facility.devices do
	local device = binder.use(scope, entry.node, Device)
	local mesh = binder.use(scope, entry.node, world3d.Mesh3D)

	mesh.configure({ mesh = cube })

	--- `Mesh3D` already `use`d a `Material3D` on this node and hands it back here,
	--- so this is the same binding a `binder.use` or `binder.get` would return —
	--- one fewer nil-check for a thing that is always there.
	mesh.material3d.configure({
		color = device.tint,
		--- THE DIM IS THE DEMO'S VISUAL: a tripped breaker reads as unlit rather
		--- than as a different colour. `brightness` scales the diffuse-and-ambient
		--- term and never the specular one, so a dark device still catches a
		--- highlight and reads as unpowered rather than as absent. Darkening
		--- `color` instead would take the highlight with it.
		brightness = reactive.computed(scope, function(use: reactive.Use): number
			return if use(device.lit) then 1 else 0.18
		end),
	})
end

-- ── The UI ───────────────────────────────────────────────────────────────────────

--- Each gets its OWN node under `uiNode`, and that is load-bearing rather than
--- tidy: a class configures `layout.Box`, `layout.Flex` and `render.Draw` on the node
--- it is handed, so binding both to `uiNode` would have them overwrite each other's
--- size, fill and visibility. It also gives the row below two children to lay out
--- instead of one node configured three times.
local panelNode = binder.node.create(uiNode)
local overlayNode = binder.node.create(uiNode)

--- NEITHER TAKES A FONT SYSTEM, and the `fonts` above is here only for `drawText`.
--- `uitext.Text` searches upward for the `Fonts` on `uiNode`, which is an ancestor of
--- both of these nodes, so no font handle has to travel through two files and four
--- functions that never look at it.
local panel = binder.use(scope, panelNode, Panel)
panel.showFacility(facility)

local overlay = binder.use(scope, overlayNode, Overlay)
overlay.showInfo()

--- THE CAMERA SWAP, and it is this short because `Camera3D` does not name a driver.
---
--- The mechanism is the effect's own child scope, which `@polywog/reactive` destroys
--- before each re-run. Picking the other controller in the overlay therefore tears
--- down the previous one, releases its binding, and builds the other — with no
--- teardown code written here. And because `unbind` RETAINS the last value, the
--- camera holds still at the handoff instead of snapping back to a default.
---
--- The two mutable locals below ARE manual bookkeeping, and they are the honest cost
--- of this arrangement: the write stage has to feed mouse input to whichever driver
--- is attached, and it is not a reactive reader, so something has to carry that
--- across. Exactly one is non-nil at a time, which nothing enforces. The
--- alternative — routing input through a cell both controllers read — would put
--- per-frame mouse deltas into the graph to avoid two locals, which is a worse trade.
--- Neither controller knows about the other, and `Camera3D` knows about neither.
local activeOrbit: OrbitController.OrbitController? = nil
local activeAutoPan: AutoPanController.AutoPanController? = nil

reactive.effect(scope, function(use: reactive.Use, controllerScope: reactive.Scope): reactive.Destructor?
	if use(overlay.controller) == "orbit" then
		local orbit = binder.use(controllerScope, playerNode, OrbitController)
		activeOrbit = orbit
		activeAutoPan = nil
		reactive.bind(controllerScope, camera.position, orbit.position)
	else
		local autoPan = binder.use(controllerScope, playerNode, AutoPanController)
		activeOrbit = nil
		activeAutoPan = autoPan
		reactive.bind(controllerScope, camera.position, autoPan.position)
	end

	return nil
end)

--- `Screen` is the whole UI half of the frame: it owns the layout root, the
--- constraints cell, the renderer, the pointer, the walk, `render.execute` and the hit
--- submission. What is left here is the two seams it cannot supply — where input comes
--- from and how text reaches the GPU.
---
--- It also puts a filled `layout.Box` on this node itself, so this file adds none.
--- `binder.use` is idempotent, so the `Flex` below lands on the same node and applies
--- to that same Box.
local screen = binder.use(scope, uiNode, screenmod.Screen)

screen.configure({
	--- `input.getEvents` is ALSO called by the write stage below, and two consumers of
	--- an input queue reads like a bug. It is not: `getEvents` CLONES the frame's
	--- event list rather than draining it, so both see the whole frame. What must not
	--- happen is a second `input.processWindowInput` — `app.Window` pumps the OS queue
	--- at band -100 and a host that pumps it again eats events before either reader
	--- gets there.
	getEvents = input.getEvents,
	--- The whole text seam, in one line. Handing a `render.TextArea` to the text
	--- renderer's `prepare` needs a cast, and `@polywog/ui/text` is the one place that
	--- can see both of those types — so it carries the cast rather than every host.
	drawText = fonts.drawText,
})

binder.use(scope, uiNode, layout.Flex).configure({ direction = "row" })

-- ── The frame ────────────────────────────────────────────────────────────────────

--- Still needed, and for exactly one reading. `Frame` hands every stage `(dt, time)`,
--- and `time` IS this clock's `now()` — the winit runner advances the clock and passes
--- its accumulated value straight through — so the throttle below reads the parameter.
--- What has no substitute is `fps()`, an EMA over raw frame times rather than `1/dt`;
--- that smoothing is the whole reason the readout is legible, so the clock stays.
local frameClock = clock.frame()

--- How often the frame-rate readout retargets its spring. A throttle, and the reason is
--- worth understanding before removing it.
---
--- Retargeting a spring is not a cheap write: changing the target RECALCULATES the
--- motion's parameters on the spot. Advancing an already-seeded spring is cheap by
--- comparison. So the cost is per RETARGET, not per frame of animation.
---
--- Frame rate is a target that changes every frame, so retargeting on every sample makes
--- the cost scale with the frame rate — and that is a feedback loop, not just an
--- overhead: a faster loop buys itself more retarget work, which pulls the rate back
--- down. Unbounded, the equilibrium is unstable, so the frame rate both swings and sits
--- lower than it should. Bounded to 10Hz the retarget cost becomes absolute rather than
--- rate-proportional, and the rate settles.
---
--- The spring interpolates between samples, so the bar reads continuously at either rate.
--- Smoothing at sample time instead does NOT substitute: that ties smoothness to the
--- sample rate, and at 10Hz the bar visibly steps.
local FPS_SAMPLE_INTERVAL = 0.1
local lastFpsSample = 0

--- THE ONE STAGE THIS DEMO REGISTERS. Everything about ordering — sync the window
--- size, batch the writes, then pull the render walk — is `Frame`'s; what is left here
--- is this demo's own logic.
---
--- BAND 10, and the number is load-bearing rather than arbitrary. `app.Window` pumps
--- input at -100 and syncs the surface at 0; `Screen` dispatches pointer input at 0;
--- the orbit gate below reads `screen.hovered`, which THAT dispatch writes. At band 0
--- the tie would break on registration order and this would read the previous frame's
--- hover — one frame of lag on a gate, which looks like nothing and is wrong. 10 also
--- leaves room for a stage that wants to run between the two.
---
--- No `reactive.batch` here: `Frame.step` wraps the entire write phase in one, so the
--- whole invalidation wave still costs a single flush. Adding another would nest.
frame.onWrite(scope, function(dt: number, time: number)
	local events = input.getEvents()
	local orbit = activeOrbit

	for _, event in events do
		if event.type == "keyDown" then
			if event.key == "KeyE" then
				overlay.toggle()
			end
		elseif event.type == "scroll" then
			if orbit ~= nil then
				orbit.applyZoom(event.dy)
			end
		end
	end

	--- Orbit only while the left button is down and the cursor is NOT over the
	--- UI — otherwise dragging the reset bar would also swing the camera.
	--- `screen.hovered` is the render walk's own hit list talking, so this stays
	--- correct as the panel changes shape.
	if orbit ~= nil
		and reactive.peek(screen.buttons).left
		and reactive.peek(screen.hovered) == nil
	then
		local delta = input.getMouseDelta()
		orbit.applyDrag(delta.x, delta.y)
	end

	local autoPan = activeAutoPan
	if autoPan ~= nil then
		autoPan.advance(dt)
	end

	--- Only while the overlay is open, and this is a real cost rather than tidiness.
	--- `sampleFps` retargets a spring, the spring's value sizes the fps bar, and a
	--- size is a LAYOUT input — so sampling every frame makes the entire UI tree dirty
	--- every frame, which in turn re-measures every text label (each `measureAt` costs
	--- two reshapes): layout runs twice per frame with nothing moving.
	--- Gated on the overlay being open AND throttled, for two different reasons. The
	--- gate: a shut overlay needs no readout, so it pays nothing at all. The throttle:
	--- retargeting the spring is what costs, not sampling — see FPS_SAMPLE_INTERVAL.
	if reactive.peek(overlay.open) then
		if time - lastFpsSample >= FPS_SAMPLE_INTERVAL then
			lastFpsSample = time
			overlay.sampleFps(frameClock:fps())
		end
	end

	animation.advance()
end, 10)

--- NO `window.handle:onUpdate(...)`. `Window.handle` is public and `onUpdate`
--- REPLACES the callback rather than adding one, so a host that registers there
--- silently unhooks `app.Window`'s own driver: no `step`, no `present`, nothing
--- rendered, exit code 0 and a blank window. Per-frame work belongs on
--- `frame.onSync`/`onWrite`/`onRender`, which is what the stage above is.
window.handle:runAsync()

scope.destroy()
