--!strict
--- Builds the facility, and it is the one file where the demo's thesis is
--- visible as shape rather than as prose.
---
--- The TREE is ownership: `facility` owns two rooms and two breakers, a room owns
--- its devices, and destroying any node destroys what it owns. The CIRCUITS are a
--- second graph laid over that tree: `subBreaker` is a SIBLING of the rooms, not
--- an ancestor of the devices it powers.
---
---     facility
---     |-- mainBreaker        Circuit    <-- both lamps, AND subBreaker's whole load
---     |-- subBreaker         Circuit    <-- both fans; fed from mainBreaker
---     |-- roomA
---     |   |-- lamp           Device + Transform
---     |   `-- fan            Device + Transform
---     `-- roomB
---         |-- lamp           Device + Transform
---         `-- fan            Device + Transform
---
--- Two independent graphs over one set of nodes is the thing to notice. If ownership
--- were the only graph available, "powered by" would have to be parenting, and a fan
--- cannot be inside a room and inside a breaker at once. Here an edge is an ordinary
--- `use` reference, so the two axes stay independent — and because they are
--- independent, a connection crossing rooms, or worlds, needs no special case either.
---
--- The emergent result is worth stating because nothing declares it: switch on
--- one machine too many and a whole room goes dark. No rule anywhere says so.

local reactive = require("@polywog/reactive")
local binder = require("@polywog/binder")

local world3d = require("@polywog/world/3d")

local Circuit = require("./Circuit")
local Device = require("./Device")

export type Entry = {
	read name: string,
	read node: binder.Node,
}

export type Facility = {
	read node: binder.Node,
	--- Flat, in declaration order, for the Panel and the Scene to walk. The tree
	--- remains the truth; these are a convenience view of it.
	read devices: { Entry },
	read circuits: { Entry },
}

--- Watts, capacity and where the cube sits, kept together so the whole facility
--- is one readable table rather than forty imperative lines.
---
--- The numbers are tuned so each scenario trips EXACTLY ONE breaker, which is what
--- makes them legible. Load flows upstream, so the main sees everything:
---   * both lamps      = 120 W on a 100 W main   -> the MAIN trips, both rooms dark
---   * both fans       =  75 W on a  60 W sub    -> the SUB trips; the main sees the
---                                                  same 75 W and is fine, so only
---                                                  the fans go dark
---   * any one device alone                      -> safe on both circuits
---   * a lamp + a fan  = 60 + 40 = 100 W         -> exactly at capacity, still safe
---
--- The sub's total (75 W) is deliberately BELOW the lamps' total (120 W). If it were
--- above, overloading the sub would push the main past its own capacity too and both
--- would trip at once — true to life, and unreadable as a demonstration.
local LAYOUT = {
	{
		room = "roomA",
		devices = {
			{
				name = "roomA.lamp",
				watts = 60,
				breaker = "main",
				position = vector.create(-2, 0.5, -1.5),
				tint = vector.create(0.95, 0.85, 0.45, 1),
			},
			{
				name = "roomA.fan",
				watts = 40,
				breaker = "sub",
				position = vector.create(-2, 0.5, 1.5),
				tint = vector.create(0.45, 0.75, 0.95, 1),
			},
		},
	},
	{
		room = "roomB",
		devices = {
			{
				name = "roomB.lamp",
				watts = 60,
				breaker = "main",
				position = vector.create(2, 0.5, -1.5),
				tint = vector.create(0.95, 0.6, 0.4, 1),
			},
			{
				name = "roomB.fan",
				watts = 35,
				breaker = "sub",
				position = vector.create(2, 0.5, 1.5),
				tint = vector.create(0.50, 0.80, 0.90, 1),
			},
		},
	},
}

local MAIN_CAPACITY = 100
local SUB_CAPACITY = 60

local function Facility(scope: reactive.Scope, parent: binder.Node): Facility
	local facility = binder.node.create(parent)

	local mainBreaker = binder.node.create(facility)
	local subBreaker = binder.node.create(facility)

	local main = binder.use(scope, mainBreaker, Circuit)
	local sub = binder.use(scope, subBreaker, Circuit)

	reactive.set(main.capacity, MAIN_CAPACITY)
	reactive.set(sub.capacity, SUB_CAPACITY)

	--- The mains: always fed. Stated rather than left to the default, because
	--- "this is the top of the chain" is worth reading in the wiring.
	main.feedFrom(nil)

	--- The chain, in both directions from one call: trip the main and the sub loses
	--- power (not because anything checks — `sub`'s supply IS `main.powered`), and
	--- whatever the sub draws shows up in the main's load.
	sub.feedFrom(main)

	local breakerNodes: { [string]: binder.Node } = {
		main = mainBreaker,
		sub = subBreaker,
	}

	local devices: { Entry } = {}

	for _, room in LAYOUT do
		local roomNode = binder.node.create(facility)

		for _, spec in room.devices do
			local deviceNode = binder.node.create(roomNode)

			local device = binder.use(scope, deviceNode, Device)
			reactive.set(device.watts, spec.watts)
			reactive.set(device.tint, spec.tint)

			--- `world3d.Transform`, the engine's own. The demo used to ship a
			--- 33-line copy whose `rotation` was euler radians; this one's is a
			--- quaternion, and the difference is invisible here because nothing in
			--- the facility ever writes anything but `position`.
			local transform = binder.use(scope, deviceNode, world3d.Transform)
			reactive.set(transform.position, spec.position)

			--- The crossing edge. `deviceNode` is under `roomNode`; the breaker
			--- it draws from is somewhere else entirely.
			local breakerNode = breakerNodes[spec.breaker]
			assert(breakerNode ~= nil, `unknown breaker: {spec.breaker}`)
			device.powerFrom(breakerNode)

			table.insert(devices, { name = spec.name, node = deviceNode })
		end
	end

	return {
		node = facility,
		devices = devices,
		circuits = {
			{ name = "main", node = mainBreaker },
			{ name = "sub", node = subBreaker },
		},
	}
end

return Facility
