--!strict
--- The persistent panel: one card per circuit, one row per device.
---
--- There is no `update` function in this file, and that is the point worth
--- noticing. Every bar width and every indicator colour is a `Computed` handed to
--- `configure`, so it FOLLOWS its source as a real graph edge. The alternative —
--- an effect that writes `fill` — looks three lines longer and is worse in a way
--- that is easy to miss: `fill` would not be a function of the thing it displays,
--- just a cell a side effect happened to write, so anything reading both could
--- observe them disagreeing inside one flush.
---
--- Numerals AND bars, each doing what the other cannot. A bar's width carries the
--- comparison — "is it near capacity?" is easier to see than to read — while the label
--- gives the exact figures a bar can only approximate. Where the two would encode the
--- SAME number, only one of them is drawn: a device row shows its watts as a numeral and
--- no bar, because two encodings of one value just make a reader check whether they
--- agree.
---
--- Every label's content is a `Computed<string>` handed to `uitext.Text`, so nothing
--- here polls or refreshes either. A `TextBuffer` is a mutable engine object outside the
--- reactive graph, and keeping one in step with a cell takes an effect rather than a
--- `bind`; `@polywog/ui/text` owns that seam, so no file here has to.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local layout = require("@polywog/ui/layout")
local render = require("@polywog/ui/render")
local pointer = require("@polywog/ui/pointer")
local animation = require("@polywog/animation")
local uitext = require("@polywog/ui/text")

local Circuit = require("../power/Circuit")
local Device = require("../power/Device")

export type Entry = {
	read name: string,
	read node: binder.Node,
}

export type FacilityView = {
	read devices: { Entry },
	read circuits: { Entry },
}

export type Panel = {
	--- Configure-after-use: a binder class takes no props, so the panel is handed what
	--- it should display after it exists.
	---
	--- It takes no font system: `uitext.Text` searches upward for a `uitext.Fonts`, so
	--- there is no font handle here, no ordering to get wrong, and nothing for a caller
	--- to supply that this file never looks at.
	read showFacility: (facility: FacilityView) -> (),
}

local BACKGROUND = vector.create(0.08, 0.085, 0.11, 0.92)
local CARD = vector.create(0.13, 0.14, 0.18, 1)
local ROW = vector.create(0.16, 0.17, 0.22, 1)
local BAR_TRACK = vector.create(0.10, 0.10, 0.13, 1)
local BAR_SAFE = vector.create(0.35, 0.75, 0.45, 1)
local BAR_NEAR = vector.create(0.90, 0.75, 0.30, 1)
local BAR_OVER = vector.create(0.90, 0.35, 0.30, 1)
local LIT = vector.create(0.95, 0.85, 0.45, 1)
local UNLIT = vector.create(0.22, 0.22, 0.26, 1)
local IDLE = vector.create(0.28, 0.30, 0.38, 1)

--- `ARMED` and `HOVER` are surfaces a label sits on, so both are dark enough for light
--- text.
local HOVER = vector.create(0.32, 0.36, 0.46, 1)
local ARMED = vector.create(0.56, 0.20, 0.18, 1)

local LABEL = vector.create(0.86, 0.89, 0.94, 1)
local LABEL_DIM = vector.create(0.84, 0.87, 0.93, 1)

--- `uitext.Text` defaults to 16, matching `text.createBuffer`; this demo's type is 13.
--- The size is stated at the call sites, one constant per file that draws text, so the
--- choice is visible rather than buried.
local FONT_SIZE = 13

--- The fraction of capacity above which a circuit's load bar turns amber: at or below
--- it the bar is `BAR_SAFE`, above it `BAR_NEAR`, and past 1 — a real overload — it is
--- `BAR_OVER`. Both comparisons are strict `>`, matching the breaker's own trip test in
--- `power/Circuit.luau`, so a circuit sitting exactly AT capacity is amber and not red —
--- for the same reason it has not tripped.
local NEAR_CAPACITY = 0.8

--- `CARD_GAP` is LOAD-BEARING, not styling. `PANEL_GAP` is not.
---
--- The render walk splits its run list at every text run, since a quad emitted afterwards
--- might overlap glyphs already drawn. It merges instead when the later quad is strictly
--- disjoint from the text, and "strictly" is exact. At a FRACTIONAL edge a quad paints
--- past the integer floor of its rect (one ending at x = 32.4 still writes column 32, at
--- partial alpha), so a touching edge really can bleed into a glyph. At an integer edge it
--- cannot, but `layout.resolveUDim` rounds nothing and a label's height is
--- `fontSize * 1.2`, so edges here are fractional essentially always.
---
--- `CARD_GAP` separates a card's heading from the load bar beneath it, and nothing else
--- provides that gap: at zero the panel goes from 2 render runs to 4. `PANEL_GAP` is free
--- to change only incidentally. A card is a fixed 64px tall while its content sums to
--- 63.6, and that 0.4px of slack is what protects the boundary it appears to guard, from
--- a card's reset label to the next card's background. Give a card a height equal to its
--- content and `PANEL_GAP` becomes load-bearing too. `test.luau`'s Phase 4 asserts the
--- run count, so either regression fails there rather than going unnoticed.
local CARD_GAP = 6
local PANEL_GAP = 10

--- One node with a `Box` and a `Draw`. Three calls per painted node is the floor the
--- API sets; this is the local shorthand for it.
---
--- It returns the `Box` alongside the node, because almost every caller wants to size
--- what it just made. `binder.use` is idempotent per (node, class), so re-acquiring
--- would have been correct too — but then every call site reads as a lookup where
--- acquisition was meant, and a reader has to know that to be sure it is not a bug.
local function paintedNode(
	scope: reactive.Scope,
	parent: binder.Node,
	config: render.DrawConfig
): (binder.Node, layout.Box)
	local node = binder.node.create(parent)
	local box = binder.use(scope, node, layout.Box)
	binder.use(scope, node, render.Draw).configure(config)
	return node, box
end

local Panel = binder.class(function(node: binder.Node, scope: reactive.Scope): Panel
	binder.use(scope, node, layout.Box).configure({
		size = layout.size(layout.px(300), layout.scale(1)),
	})
	binder.use(scope, node, layout.Flex).configure({
		direction = "column",
		gap = PANEL_GAP,
	})
	binder.use(scope, node, render.Draw).configure({
		fill = BACKGROUND,
		clip = true,
	})

	local function addCircuitCard(entry: Entry)
		local circuit = binder.use(scope, entry.node, Circuit)

		local card, cardBox = paintedNode(scope, node, { fill = CARD, radius = layout.px(6) })
		cardBox.configure({ size = layout.size(layout.scale(1), layout.px(64)) })
		binder.use(scope, card, layout.Flex).configure({ direction = "column", gap = CARD_GAP })

		--- The heading. The bar below still carries the comparison — this only names
		--- the circuit and gives the exact figures, which a bar cannot.
		local heading = binder.node.create(card)
		binder.use(scope, heading, uitext.Text).configure({
			content = reactive.computed(scope, function(use: reactive.Use): string
				return `{entry.name}  {math.floor(use(circuit.load))} / {math.floor(use(circuit.capacity))} W`
			end),
			color = LABEL,
			fontSize = FONT_SIZE,
		})

		--- The load bar. Its width IS `load / capacity`, so the bar is not a readout of
		--- the number — it is the number.
		local track, trackBox = paintedNode(scope, card, { fill = BAR_TRACK, radius = layout.px(4) })
		trackBox.configure({ size = layout.size(layout.scale(1), layout.px(14)) })

		--- Springed, so the bar EASES to a new load instead of snapping. The value it
		--- tracks is genuinely a step — a device toggles — but a step is exactly what a
		--- reader can miss; the travel is what makes "it just moved" visible. And it is
		--- one line, on real data rather than on chrome.
		local ratio = reactive.computed(scope, function(use: reactive.Use): number
			return math.clamp(use(circuit.load) / use(circuit.capacity), 0, 1)
		end)
		local easedRatio = animation.spring(scope, ratio, { frequency = 10, damping = 1 })

		local _bar, barBox = paintedNode(scope, track, {
			radius = layout.px(4),
			--- Colour reads the RAW ratio, not the springed one. An overloaded circuit
			--- should look overloaded the instant it is, rather than fading red as the
			--- bar catches up — and it can exceed 1, which the bar's width cannot.
			fill = reactive.computed(scope, function(use: reactive.Use): vector
				local exact = use(circuit.load) / use(circuit.capacity)

				if exact > 1 then
					return BAR_OVER
				elseif exact > NEAR_CAPACITY then
					return BAR_NEAR
				end

				return BAR_SAFE
			end),
		})
		barBox.configure({
			size = reactive.computed(scope, function(use: reactive.Use): layout.SizeSpec
				return layout.size(layout.scale(use(easedRatio)), layout.scale(1))
			end),
		})

		--- The reset button. Its colour says three things at once: armed (the circuit is
		--- tripped, so clicking will do something), hovered, or idle.
		local reset, resetBox = paintedNode(scope, card, { radius = layout.px(4) })
		resetBox.configure({ size = layout.size(layout.scale(1), layout.px(22)) })

		local resetHit = binder.use(scope, reset, pointer.Interactable)

		binder.use(scope, reset, render.Draw).configure({
			fill = reactive.computed(scope, function(use: reactive.Use): vector
				if use(circuit.tripped) then
					return ARMED
				elseif use(resetHit.state) == "hover" then
					return HOVER
				end

				return IDLE
			end),
		})

		--- The button says what it does, and what it will do. Without the label these
		--- are bare coloured bars, legible only once you have already clicked one.
		local resetLabel = binder.node.create(reset)
		binder.use(scope, resetLabel, uitext.Text).configure({
			content = reactive.computed(scope, function(use: reactive.Use): string
				return if use(circuit.tripped) then "reset (tripped)" else "reset"
			end),
			color = LABEL_DIM,
			fontSize = FONT_SIZE,
		})

		resetHit.onClick(scope, function(): boolean
			circuit.reset()
			return true
		end)
	end

	local function addDeviceRow(entry: Entry)
		local device = binder.use(scope, entry.node, Device)

		local row, rowBox = paintedNode(scope, node, { fill = ROW, radius = layout.px(4) })
		rowBox.configure({ size = layout.size(layout.scale(1), layout.px(28)) })
		binder.use(scope, row, layout.Flex).configure({
			direction = "row",
			gap = CARD_GAP,
			align = "center",
		})

		--- The toggle. Clicking flips `switch`, and everything downstream — the
		--- device's demand, the circuit's load, whether it trips, whether the cube
		--- glows — follows from that one write.
		local toggle, toggleBox = paintedNode(scope, row, { radius = layout.px(3) })
		toggleBox.configure({ size = layout.offset(40, 20) })

		local toggleHit = binder.use(scope, toggle, pointer.Interactable)

		binder.use(scope, toggle, render.Draw).configure({
			fill = reactive.computed(scope, function(use: reactive.Use): vector
				if use(device.switch) then
					return HOVER
				elseif use(toggleHit.state) == "hover" then
					return IDLE
				end

				return UNLIT
			end),
		})

		toggleHit.onClick(scope, function(): boolean
			reactive.set(device.switch, not reactive.peek(device.switch))
			return true
		end)

		--- The lit indicator, and note that it reads `lit` rather than `switch`: a
		--- device can be switched on and dark, which is the whole demo in one dot.
		--- `layout.scale(0.5)` as the radius resolves against the shorter side, so
		--- it is a circle rather than a rounded square.
		local _lamp, lampBox = paintedNode(scope, row, {
			radius = layout.scale(0.5),
			fill = reactive.computed(scope, function(use: reactive.Use): vector
				return if use(device.lit) then LIT else UNLIT
			end),
		})
		lampBox.configure({ size = layout.offset(18, 18) })

		--- The watts as a numeral, and deliberately not also as a bar. Two encodings of
		--- one number leave a reader working out whether they agree, and the numeral is
		--- the exact one.
		local watts = binder.node.create(row)
		binder.use(scope, watts, uitext.Text).configure({
			content = reactive.computed(scope, function(use: reactive.Use): string
				return `{entry.name}  {math.floor(use(device.watts))} W`
			end),
			color = LABEL_DIM,
			fontSize = FONT_SIZE,
		})
	end

	local function showFacility(facility: FacilityView)
		for _, entry in facility.circuits do
			addCircuitCard(entry)
		end

		for _, entry in facility.devices do
			addDeviceRow(entry)
		end
	end

	return { showFacility = showFacility }
end)

return Panel
