--!strict
--- MIXED — data and behaviour in one binder, and this file is the demo's
--- counter-example on purpose.
---
--- The camera is split into a data binder (`world3d.Camera3D`) plus a driver
--- (`camera/OrbitController.luau`, `camera/AutoPanController.luau`) because it has
--- several possible drivers and swapping them is the point. A lamp has exactly one
--- driver and always will: a switch. Splitting it would give three files, two
--- more `use` calls and one more indirection to buy nothing.
---
--- Without this file the lesson a reader takes from the camera is "always split",
--- which is worse than not teaching the pattern at all. The rule is: split when
--- the driver is genuinely replaceable, not on principle.
---
--- The one thing worth copying here regardless is how a device joins a circuit.
--- It pushes its own demand in and registers the removal on its own scope, so the
--- circuit never discovers anything and destroying the device unwires it. Power
--- draw is a property of the RELATIONSHIP, and hiding it from the device would be
--- less honest rather than more decoupled.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local set = require("@polywog/reactive/set")

local Circuit = require("./Circuit")

export type Device = {
	read switch: reactive.Value<boolean>,
	read watts: reactive.Value<number>,

	--- What it WANTS to draw, independent of whether it is getting any.
	---
	--- Physically a dark lamp draws nothing. Modelling that — `use(switch) and
	--- use(supplied)` — is the tempting "correction", and it is wrong for a reason
	--- that has nothing to do with physics: modelling INTENT is what keeps `load`
	--- meaningful. A circuit's load is what is being ASKED of it, so it still reads
	--- 120 W on a 100 W breaker after the breaker trips — which is precisely the
	--- number that explains why it tripped. Under the correction a tripped circuit
	--- reports 0 W, and the panel shows a tripped breaker sitting at no load with
	--- nothing anywhere saying why.
	---
	--- Do NOT expect the runtime to catch the correction for you. It looks like a
	--- cycle — `load -> demand -> supplied -> powered` — but `tripped` is a `Value`
	--- that an effect WRITES rather than a `Computed` the graph reads through, and a
	--- write is not a dependency edge. So there is no dependency cycle to detect, and
	--- `@polywog/reactive` is right not to raise one. The failure mode is a quietly
	--- incoherent readout, not an error, which is why the rule is stated here.
	read demand: reactive.Computed<number>,

	--- On AND supplied. This is what the world renders.
	read lit: reactive.Computed<boolean>,

	--- Colour when lit, read by `main.luau`, which binds it to the device's `Material3D.color`.
	read tint: reactive.Value<vector>,

	--- Configure-after-use. Joins `circuitNode`'s circuit, and unjoins when this
	--- device's scope dies.
	read powerFrom: (circuitNode: binder.Node) -> (),
}

--- Deliberately not plausible numbers. `power/Facility.luau` sets every real watt
--- figure and tint, and a believable default here would be a decoy for a reader
--- trying to change one.
local UNCONFIGURED_WATTS = 0
local UNCONFIGURED_TINT = vector.create(1, 0, 1, 1)

local Device = binder.class(function(_node: binder.Node, scope: reactive.Scope): Device
	local switch = reactive.value(scope, false)
	local watts = reactive.value(scope, UNCONFIGURED_WATTS)
	local tint = reactive.value(scope, UNCONFIGURED_TINT)

	--- Rebound by `powerFrom`. Until then a device is unwired and never lit, which is
	--- the honest reading of "not plugged into anything".
	---
	--- Declared BEFORE `demand` on purpose: a Luau local is only in scope after its
	--- declaration, so a `demand` written above this line that referred to `supplied`
	--- would silently resolve to a nil global instead.
	local supplied = reactive.value(scope, false)

	local demand = reactive.computed(scope, function(use: reactive.Use): number
		return if use(switch) then use(watts) else 0
	end)

	local lit = reactive.computed(scope, function(use: reactive.Use): boolean
		return use(switch) and use(supplied)
	end)

	local function powerFrom(circuitNode: binder.Node)
		--- `use`, not `get`: `get` returns `Circuit?` and every line below would
		--- need a nil-check for a binding that is supposed to be there. `use` is
		--- idempotent and returns `Circuit`, so if the breaker node already has
		--- one this shares it, and if it does not this creates it.
		local circuit = binder.use(scope, circuitNode, Circuit)

		set.add(circuit.contributions, demand)
		scope.add(function()
			set.remove(circuit.contributions, demand)
		end)

		reactive.bind(scope, supplied, circuit.powered)
	end

	return {
		switch = switch,
		watts = watts,
		demand = demand,
		lit = lit,
		tint = tint,
		powerFrom = powerFrom,
	}
end)

return Device
