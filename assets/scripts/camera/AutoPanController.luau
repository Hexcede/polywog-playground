--!strict
--- BEHAVIOUR binder. Circles the facility on its own, forever.
---
--- It exists to be swapped in for `OrbitController`, and the interesting thing is
--- how little the two have to agree on: both publish a
--- `position: Computed<vector>` and that is the entire contract. Neither mentions
--- `Camera3D`; `Camera3D` mentions neither. Swap them and no third file changes.
---
--- There is deliberately NO spring here. An earlier draft springed `angle` and
--- claimed that made the handoff ease rather than snap; it does not. The spring
--- would start already settled on the angle's initial value, so it has nothing to
--- travel from, and the camera still jumps at the moment of the swap. All it would
--- add is lag on a value that is already continuous, plus a comment that reads
--- true and is not. Animation earns its place in `ui/Overlay.luau`, where
--- something genuinely moves between two states.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")

export type AutoPanController = {
	read position: reactive.Computed<vector>,
	--- Advanced by `main.luau` in the write phase, exactly like the orbit
	--- controller's input methods: a driver does not decide when in the frame it
	--- moves.
	read advance: (dt: number) -> (),
}

local RADIUS = 12
local HEIGHT = 5
local RATE = 0.25

local AutoPanController = binder.class(function(_node: binder.Node, scope: reactive.Scope): AutoPanController
	local angle = reactive.value(scope, 0)

	local position = reactive.computed(scope, function(use: reactive.Use): vector
		local a = use(angle)

		return vector.create(
			math.sin(a) * RADIUS,
			HEIGHT,
			math.cos(a) * RADIUS
		)
	end)

	local function advance(dt: number)
		reactive.update(angle, function(current: number): number
			return current + dt * RATE
		end)
	end

	return {
		position = position,
		advance = advance,
	}
end)

return AutoPanController
