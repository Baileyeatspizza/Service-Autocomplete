local Services = {}

local PREDEFINED = {
	"ReplicatedStorage",
	"MemoryStoreService",
}

local function isService(instance)
	-- avoid unnamed instances
	assert(instance.Name ~= "Instance", "Can't autocomplete unnamed services")

	-- it shouldn't be possible to create another service prevents highest level user made instances from appearing
	local createdInstance = pcall(function()
		return instance.new(instance.ClassName)
	end)

	if createdInstance then
		return
	end

	-- final check to ensure that the service can be called upon
	return game:GetService(instance.ClassName)
end

local function checkIfService(instance)
	local success = pcall(isService, instance)
	if success then
		Services[instance.ClassName] = true
	else
		pcall(function()
			Services[instance.ClassName] = false
		end)
	end
end

game.ChildAdded:Connect(checkIfService)
for _, v in game:GetChildren() do
	checkIfService(v)
end

for _, v in PREDEFINED do
	checkIfService(v)
end

return Services
