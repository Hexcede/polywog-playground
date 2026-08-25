--!strict
--- The `E` overlay: a panel that slides and fades in, carrying the frame-rate
--- readout and the camera-controller switcher.
---
--- Two things worth reading. `openness` is ONE springed number and everything
--- visual is derived from it — the width, the background alpha, and whether the
--- overlay exists to the hit-tester at all. "Open" is a single boolean; the motion
--- is a consequence, not a second piece of state to keep in sync.
---
--- And the switcher does not switch anything. It writes a `Value`, and `main.luau`
--- is what builds one controller and tears down the other. This file has never
--- heard of a controller — it deals in a two-case enum.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local layout = require("@polywog/ui/layout")
local render = require("@polywog/ui/render")
local pointer = require("@polywog/ui/pointer")
local animation = require("@polywog/animation")
local uitext = require("@polywog/ui/text")

export type ControllerKind = "orbit" | "autoPan"

export type Overlay = {
	read toggle: () -> (),
	read open: reactive.Value<boolean>,
	--- Which controller the reader picked. A `Value`, so `main.luau` can follow it
	--- with an effect — and so a test can write it directly.
	read controller: reactive.Value<ControllerKind>,
	--- Pushed from the frame, because frame rate is not a reactive source: nothing
	--- invalidates when the next frame happens to take longer.
	read sampleFps: (fps: number) -> (),

	--- Configure-after-use, because a binder class takes no props. It takes nothing at
	--- all: `uitext.Text` searches upward for a `uitext.Fonts`, so the labels below need
	--- no font system handed in.
	read showInfo: () -> (),
}

local BACKGROUND = vector.create(0.06, 0.07, 0.10, 0.94)

--- Every colour in this block that a LABEL sits on has to stay dark enough for light
--- text. `SELECTED` is a deep blue rather than a bright one for exactly that reason:
--- still unmistakably the "on" state against the neutral grey of `UNSELECTED`, but with
--- the contrast a reader needs.
local SELECTED = vector.create(0.16, 0.36, 0.66, 1)
local UNSELECTED = vector.create(0.20, 0.22, 0.28, 1)
local HOVERED = vector.create(0.24, 0.28, 0.36, 1)
local FPS_BAR = vector.create(0.45, 0.80, 0.55, 1)
local LABEL = vector.create(0.86, 0.89, 0.94, 1)
local LABEL_DIM = vector.create(0.84, 0.87, 0.93, 1)
local TRACK = vector.create(0.10, 0.10, 0.13, 1)

local WIDTH = 320

--- Same 13 `ui/Panel.luau` carries. `uitext.Text` defaults to 16, so each file that
--- draws text states its own size.
local FONT_SIZE = 13

local FPS_BASE = 60
local VISIBLE_THRESHOLD = 0.01

local Overlay = binder.class(function(node: binder.Node, scope: reactive.Scope): Overlay
	local open = reactive.value(scope, false)
	local controller = reactive.value(scope, "orbit" :: ControllerKind)

	--- One number drives the whole transition. The spring is what makes it a
	--- transition rather than a toggle.
	local target = reactive.computed(scope, function(use: reactive.Use): number
		return if use(open) then 1 else 0
	end)
	local openness = animation.spring(scope, target, { frequency = 9, damping = 1 })

	--- This node's own fill only. `Draw.clip` below crops text as well as quads, so the
	--- labels need no visibility plumbing of their own.
	local contentVisible = reactive.computed(scope, function(use: reactive.Use): boolean
		return use(openness) > VISIBLE_THRESHOLD
	end)

	binder.use(scope, node, layout.Box).configure({
		--- The width follows `openness`, so the panel slides out rather than
		--- appearing. At 0 it is zero-wide and the layout gives it nothing.
		size = reactive.computed(scope, function(use: reactive.Use): layout.SizeSpec
			return layout.size(layout.px(WIDTH * use(openness)), layout.scale(1))
		end),
	})
	binder.use(scope, node, layout.Flex).configure({ direction = "column", gap = 10 })
	binder.use(scope, node, render.Draw).configure({
		fill = reactive.computed(scope, function(use: reactive.Use): vector
			local alpha = use(openness)
			return vector.create(BACKGROUND.x, BACKGROUND.y, BACKGROUND.z, BACKGROUND.w * alpha)
		end),
		--- Clips this subtree, glyphs included. That is what lets the labels below be
		--- ordinary children with no visibility plumbing of their own.
		clip = true,
		--- Governs this node's own fill and nothing else: not its children, and not
		--- hit-testing, which the walk records before it consults visibility.
		---
		--- Collapsing the width does most of the work anyway: the walk prunes a node
		--- whose rect does not intersect its clip, before recording a hit or descending.
		--- This flag covers the frames where the spring has not quite reached zero.
		visible = contentVisible,
	})

	--- The frame-rate readout, springed — and the interesting part is what that costs.
	---
	--- A spring is cheap to advance and expensive to RETARGET: a new target recalculates
	--- the motion's parameters on the spot. Frame rate changes every frame, so retargeting
	--- per sample makes the cost scale with the frame rate, which is a feedback loop
	--- rather than a fixed overhead. The host bounds the retarget rate, since only the
	--- host knows the frame. Layout churn is not the cost here; the reseed is.
	local rawFps = reactive.value(scope, 60)
	local smoothFps = animation.spring(scope, rawFps, { frequency = 2, damping = 1 })

	--- The bar's full-scale reference, and it has to move: a fixed 120 pinned the bar
	--- at full in a release build (measured 800-1000 fps against 90 in debug), so the
	--- one readout built to show frame-time variation showed a solid block instead.
	--- Tracking a running maximum, rounded up to a multiple of the base, keeps the bar
	--- meaningful in both profiles. It never decreases, so a one-off spike permanently
	--- lowers the bar — accepted, because the numeral beside it always carries the
	--- exact figure and the bar's job is only to make a lurch visible.
	local fpsCeiling = reactive.value(scope, FPS_BASE)

	local fpsTrack = binder.node.create(node)
	binder.use(scope, fpsTrack, layout.Box).configure({
		size = layout.size(layout.scale(1), layout.px(10)),
	})
	binder.use(scope, fpsTrack, render.Draw).configure({ fill = TRACK, radius = layout.px(3) })

	local fpsBar = binder.node.create(fpsTrack)
	binder.use(scope, fpsBar, layout.Box).configure({
		size = reactive.computed(scope, function(use: reactive.Use): layout.SizeSpec
			local ratio = math.clamp(use(smoothFps) / use(fpsCeiling), 0, 1)
			return layout.size(layout.scale(ratio), layout.scale(1))
		end),
	})
	binder.use(scope, fpsBar, render.Draw).configure({ fill = FPS_BAR, radius = layout.px(3) })

	local function addControllerButton(kind: ControllerKind): binder.Node
		local button = binder.node.create(node)
		binder.use(scope, button, layout.Box).configure({
			size = layout.size(layout.scale(1), layout.px(26)),
		})

		local interactable = binder.use(scope, button, pointer.Interactable)

		binder.use(scope, button, render.Draw).configure({
			radius = layout.px(4),
			fill = reactive.computed(scope, function(use: reactive.Use): vector
				if use(controller) == kind then
					return SELECTED
				elseif use(interactable.state) == "hover" then
					return HOVERED
				end

				return UNSELECTED
			end),
		})

		interactable.onClick(scope, function(): boolean
			reactive.set(controller, kind)
			return true
		end)

		return button
	end

	local orbitButton = addControllerButton("orbit")
	local autoPanButton = addControllerButton("autoPan")

	local function toggle()
		reactive.set(open, not reactive.peek(open))
	end

	local function sampleFps(fps: number)
		reactive.batch(function()
			reactive.set(rawFps, fps)

			if fps > reactive.peek(fpsCeiling) then
				reactive.set(fpsCeiling, math.ceil(fps / FPS_BASE) * FPS_BASE)
			end
		end)
	end

	--- The numeral beside the bar, and the explanation the overlay exists to carry.
	---
	--- The bar stays: it makes a dropped frame visible as a lurch without the reader
	--- having to compare two numbers over time, which is the one thing a numeral is bad
	--- at.
	--- EVERY LABEL IN HERE PINS `wrapWidth` TO `WIDTH`, AND THAT IS MEASURED RATHER THAN
	--- STYLISTIC. This overlay's own width is `WIDTH * openness`, so a label left to wrap
	--- at whatever width layout currently offers re-wraps on EVERY FRAME of the slide: the
	--- text visibly reflows and the block's height changes with it, which pushes its flex
	--- siblings around. Wrapping at the container's FINAL width keeps each measured size
	--- constant while the panel travels. `@polywog/ui/text` states the rule in the
	--- abstract; this is the concrete container it was written for.
	local function showInfo()
		local fps = binder.node.create(node)
		binder.use(scope, fps, uitext.Text).configure({
			content = reactive.computed(scope, function(use: reactive.Use): string
				return `{math.floor(use(smoothFps) + 0.5)} fps`
			end),
			color = LABEL,
			fontSize = FONT_SIZE,
			wrapWidth = WIDTH,
		})

		local orbitLabel = binder.node.create(orbitButton)
		binder.use(scope, orbitLabel, uitext.Text).configure({
			content = "orbit — drag to look",
			color = LABEL_DIM,
			fontSize = FONT_SIZE,
			wrapWidth = WIDTH,
		})

		local autoPanLabel = binder.node.create(autoPanButton)
		binder.use(scope, autoPanLabel, uitext.Text).configure({
			content = "auto-pan — hands off",
			color = LABEL_DIM,
			fontSize = FONT_SIZE,
			wrapWidth = WIDTH,
		})

		local blurb = binder.node.create(node)
		binder.use(scope, blurb, uitext.Text).configure({
			content = "Each device declares the power it wants.\n"
				.. "Each breaker declares what it can supply.\n"
				.. "Nothing anywhere declares that a room goes dark.",
			color = LABEL_DIM,
			fontSize = FONT_SIZE,
			wrapWidth = WIDTH,
		})
	end

	return {
		toggle = toggle,
		open = open,
		controller = controller,
		sampleFps = sampleFps,
		showInfo = showInfo,
	}
end)

return Overlay
