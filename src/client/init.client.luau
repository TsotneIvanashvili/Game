--!strict
-- Client bootstrap. Requires every controller in an explicit order, runs all Init()s
-- (build UI, create local instances; no remotes yet), then all Start()s (connect remotes
-- and input). Each step is isolated with pcall so one broken controller only loses its
-- own feature. Start() runs in its own thread: a controller waiting on a remote can't
-- hold up the others, while non-yielding Starts still run in order.

local Controllers = script:WaitForChild("Controllers")

-- NotificationController first: others toast through it during their own Start.
local ORDER = {
	"NotificationController",
	"PanelController",
	"InventoryController",
	"BuildBookController",
	"HUDController",
	"ClimbingController",
	"MovementController",
	"AudioController",
	"WeatherController",
	"ConditionController",
	"PingController",
	"SummaryController",
}

type Controller = { Init: (() -> ())?, Start: (() -> ())? }

local loaded: { { name: string, module: Controller } } = {}
local listed: { [string]: boolean } = {}

local function load(name: string, moduleScript: Instance)
	local ok, result = pcall(require, moduleScript :: ModuleScript)
	if ok and typeof(result) == "table" then
		table.insert(loaded, { name = name, module = result :: Controller })
	else
		warn(string.format("[Client] failed to load %s: %s", name, tostring(result)))
	end
end

for _, name in ORDER do
	listed[name] = true
	local moduleScript = Controllers:FindFirstChild(name)
	if moduleScript and moduleScript:IsA("ModuleScript") then
		load(name, moduleScript)
	else
		warn("[Client] missing controller " .. name)
	end
end

-- Controllers added later but not yet given a place in ORDER still run, after the rest.
local extras: { ModuleScript } = {}
for _, child in Controllers:GetChildren() do
	if child:IsA("ModuleScript") and not listed[child.Name] then
		table.insert(extras, child)
	end
end
table.sort(extras, function(a, b)
	return a.Name < b.Name
end)
for _, moduleScript in extras do
	warn("[Client] " .. moduleScript.Name .. " is not in ORDER; starting it last")
	load(moduleScript.Name, moduleScript)
end

for _, entry in loaded do
	local init = entry.module.Init
	if init then
		local ok, err = pcall(init)
		if not ok then
			warn(string.format("[Client] %s.Init failed: %s", entry.name, tostring(err)))
		end
	end
end

for _, entry in loaded do
	local start = entry.module.Start
	if start then
		task.spawn(function()
			local ok, err = pcall(start)
			if not ok then
				warn(string.format("[Client] %s.Start failed: %s", entry.name, tostring(err)))
			end
		end)
	end
end
