--!strict
--- BEHAVIOUR binder. Orbits a point: drag with the left mouse button to swing
--- around, scroll to pull in and out.
---
--- It publishes a `position` and never touches a `Camera3D`. That is the
--- inversion: `main.luau` is what connects the two, with
--- `reactive.bind(scope, camera.position, controller.position)`, so this file
--- and `Camera3D` know nothing of each other and either can be replaced alone.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")

export type OrbitController = {
	read position: reactive.Computed<vector>,
	--- Fed the frame's input by `main.luau`, in the write phase. The angles live
	--- in `Value`s and these are what write them; a controller cannot read input
	--- itself without deciding when in the frame that happens, which is the
	--- host's call to make.
	read applyDrag: (dx: number, dy: number) -> (),
	read applyZoom: (delta: number) -> (),
}

local MIN_PITCH = -1.4
local MAX_PITCH = 1.4
local MIN_DISTANCE = 3
local MAX_DISTANCE = 24

local OrbitController = binder.class(function(_node: binder.Node, scope: reactive.Scope): OrbitController
	local yaw = reactive.value(scope, 0.6)
	local pitch = reactive.value(scope, 0.5)
	local distance = reactive.value(scope, 11)

	--- A `Computed`, so it cannot be written from outside — a driver's output is
	--- derived, and anything wanting to move the camera should attach a different
	--- driver rather than poke this one.
	local position = reactive.computed(scope, function(use: reactive.Use): vector
		local y = use(yaw)
		local p = use(pitch)
		local d = use(distance)
		local horizontal = math.cos(p) * d

		return vector.create(
			math.sin(y) * horizontal,
			math.sin(p) * d + 0.5,
			math.cos(y) * horizontal
		)
	end)

	local function applyDrag(dx: number, dy: number)
		reactive.batch(function()
			reactive.update(yaw, function(current: number): number
				return current - dx * 0.008
			end)
			reactive.update(pitch, function(current: number): number
				return math.clamp(current + dy * 0.008, MIN_PITCH, MAX_PITCH)
			end)
		end)
	end

	local function applyZoom(delta: number)
		reactive.update(distance, function(current: number): number
			return math.clamp(current - delta * 0.8, MIN_DISTANCE, MAX_DISTANCE)
		end)
	end

	return {
		position = position,
		applyDrag = applyDrag,
		applyZoom = applyZoom,
	}
end)

return OrbitController
