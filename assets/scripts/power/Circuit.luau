--!strict
--- A breaker's circuit. The demo's centre of gravity — if you read one file here,
--- read this one.
---
--- Look at `tripped` first. It is a `Value` written by an `effect`, and every other
--- cell in this file is a `computed`. That split is the lesson:
---
---   * `computed` and `bind` DERIVE. Given the inputs, the output is forced.
---   * `effect` is for state that REMEMBERS.
---
--- `tripped` is genuinely new information — nothing else in the graph holds it. Only
--- the *should-trip* condition is derivable.
---
--- Written the obvious way, `tripped = reactive.computed(scope, function(use) return
--- use(load) > use(capacity) end)`, it would not error and it would not oscillate. It
--- would simply fail to LATCH: `tripped` would track `load` exactly, so switching one
--- device back off would silently re-close the breaker, `reset` would have nothing
--- left to do, and a tripped state could never persist. A real breaker latches until
--- a human resets it, and latching is history rather than derivation.
---
--- Mostly DATA, with exactly one piece of behaviour — the latch — and it is worth
--- saying why that does not make this a driver. The effect maintains this circuit's
--- OWN state from this circuit's own inputs; it does not reach into another binder.
--- A behaviour binder in this demo's sense is one that drives *somebody else's*
--- `Value`, which is what `camera/OrbitController.luau` does and this does not.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")
local set = require("@polywog/reactive/set")

export type Circuit = {
	--- Watts. A `Value`, so the Panel — or a driver — can change it live.
	read capacity: reactive.Value<number>,

	--- Every consumer's demand, pushed here by the consumer itself.
	---
	--- A `Set` of `Computed`s rather than a list of devices, because a circuit has no
	--- business knowing what a device is. It knows it has contributions.
	read contributions: set.Set<reactive.Computed<number>>,

	read load: reactive.Computed<number>,
	read tripped: reactive.Value<boolean>,
	read powered: reactive.Computed<boolean>,

	--- Configure-after-use, because a `binder` class takes no props. `nil` means "this
	--- is the mains" — always fed.
	---
	--- Takes the upstream CIRCUIT rather than its `powered` cell, because the
	--- relationship runs in both directions and one call should establish both: power
	--- flows DOWN (tripping the main darkens this circuit) and load flows UP (whatever
	--- this circuit draws, the main is supplying too). An earlier version took a bare
	--- `State<boolean>` and could therefore only wire the downward half — which left the
	--- main's load excluding everything its own sub-circuit drew, a claim the demo could
	--- not defend to anyone who noticed.
	read feedFrom: (upstream: Circuit?) -> (),

	--- The human in the loop. `tripped` latches; this is the only thing that clears
	--- it — and if the circuit is still overloaded, it trips straight back.
	read reset: () -> (),
}

--- Deliberately not a plausible number. Every real capacity is set by
--- `power/Facility.luau`, and a default of `100` there would be a decoy: it is the
--- first `100` a reader greps for when trying to change when a breaker trips, and
--- changing it does nothing because `Facility` overwrites it.
local UNCONFIGURED_CAPACITY = 0

local Circuit = binder.class(function(_node: binder.Node, scope: reactive.Scope): Circuit
	local capacity = reactive.value(scope, UNCONFIGURED_CAPACITY)

	--- The cast is required and not incidental: `set.create` with no members has
	--- nothing to infer `V` from. Given an array literal it would infer; absent one,
	--- the result type is what states it.
	local contributions = set.create(scope) :: set.Set<reactive.Computed<number>>

	--- `Set<V>` IS a `reactive.Computed<{ [V]: true }>`, which is why this reads as
	--- one expression rather than needing a fold helper: `use(contributions)` yields
	--- the member table, and each member is itself a `State` to `use`. Adding a device
	--- re-runs this; so does any device changing its demand.
	local load = reactive.computed(scope, function(use: reactive.Use): number
		local total = 0

		for contribution in use(contributions) do
			total += use(contribution)
		end

		return total
	end)

	--- Starts as the mains: fed unless `feedFrom` says otherwise. A `Value` because
	--- `feedFrom` rebinds it, and `bind` replacing rather than stacking is what makes
	--- calling `feedFrom` twice safe instead of additive.
	local fed = reactive.value(scope, true)

	local tripped = reactive.value(scope, false)

	--- Bumped by `reset`, and read by the latch below purely so that resetting
	--- re-evaluates the overload condition.
	---
	--- Without it the latch is subtly broken in a way that looks fine: the effect
	--- depends on `load` and `capacity`, neither of which `reset` changes, so it does
	--- not re-run — and a 120 W load would sit on a 100 W breaker reading UNTRIPPED
	--- until something else happened to move the load. With it, resetting an
	--- overloaded circuit trips it straight back, which is both what real breakers do
	--- and the more instructive demo: you have to switch something off first.
	local resetEpoch = reactive.value(scope, 0)

	--- The latch. Reads the overload condition and writes history.
	---
	--- It reads `load` and `capacity` but deliberately NOT `powered`: an effect that
	--- un-trips itself when power drops would be a feedback loop through its own
	--- write, and `reactive`'s cycle detection would not catch it, because a write is
	--- not a dependency edge.
	reactive.effect(scope, function(use: reactive.Use)
		use(resetEpoch)

		if use(load) > use(capacity) then
			reactive.set(tripped, true)
		end
	end)

	local powered = reactive.computed(scope, function(use: reactive.Use): boolean
		return use(fed) and not use(tripped)
	end)

	local function feedFrom(upstream: Circuit?)
		if upstream == nil then
			--- No `isBound` guard needed: `reactive.unbind` early-returns when the value
			--- was never bound, so this is a no-op on a fresh circuit and a real release
			--- on a re-fed one.
			reactive.unbind(fed)
			reactive.set(fed, true)
			return
		end

		--- Power flows DOWN.
		reactive.bind(scope, fed, upstream.powered)

		--- And load flows UP — this circuit's whole draw becomes one contribution to
		--- the circuit feeding it, exactly as a device's demand does. A sub-panel is a
		--- consumer from the main's point of view, and nothing here needed a special
		--- case to say so: `load` is already a `Computed<number>`, which is precisely
		--- what `contributions` holds.
		---
		--- Idempotent, so calling `feedFrom` twice is safe: `contributions` is a Set, so
		--- the second `add` of the same `Computed` is a no-op.
		set.add(upstream.contributions, load)
		scope.add(function()
			set.remove(upstream.contributions, load)
		end)
	end

	--- One batch, so the clear and the re-check settle together: a reader watching
	--- `tripped` never sees it briefly false on a circuit that is about to re-trip.
	local function reset()
		reactive.batch(function()
			reactive.set(tripped, false)
			reactive.update(resetEpoch, function(current: number): number
				return current + 1
			end)
		end)
	end

	return {
		capacity = capacity,
		contributions = contributions,
		load = load,
		tripped = tripped,
		powered = powered,
		feedFrom = feedFrom,
		reset = reset,
	}
end)

return Circuit
