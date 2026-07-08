local services = {}

local generatedList = [[
AdService
AnalyticsService
AnimationClipProvider
AssetService
AvatarCreationService
AvatarEditorService
BadgeService
BrowserService
CaptureService
ChangeHistoryService
Chat
ClusterPacketCache
CollectionService
CommerceService
ConfigureServerService
ContentProvider
ContextActionService
CookiesService
DataStoreService
Debris
EncodingService
FeatureRestrictionManager
FriendService
GamePassService
GenerationService
Geometry
GroupService
GuiService
GuidRegistryService
HeapProfilerService
HttpRbxApiService
HttpService
InsertService
InstanceExtensionsService
JointsService
KeyboardService
KeyframeSequenceProvider
Lighting
LocalizationService
LogService
LuaWebService
MarketplaceService
MaterialService
MemStorageService
MicroProfilerService
ModerationService
MouseService
NetworkServer
NotificationService
OpenCloudService
PackageService
Packages
PathfindingService
PermissionsService
PhysicsService
PlacesService
Players
PluginManagementService
PointsService
PolicyService
ProcessInstancePhysicsService
ProximityPromptService
PublishService
RecommendationService
ReflectionService
RemoteCommandService
RemoteDebuggerServer
ReplicatedFirst
ReplicatedStorage
RunService
ScriptContext
ScriptProfilerService
ScriptService
Selection
SelectionHighlightManager
ServerScriptService
ServerStorage
ServiceVisibilityService
SharedTableRegistry
SlimContentProvider
SocialService
SoundService
SpawnerService
StarterGui
StarterPack
StarterPlayer
Stats
StudioTestService
StylingService
Teams
TeleportService
TestService
TextBoxService
TextChatService
TextService
TimerService
TouchInputService
TweenService
UGCValidationService
UniqueIdLookupService
UserInputService
UserService
VRService
VideoCaptureService
VideoService
VirtualInputManager
VoiceChatService
Workspace
]]

for service in string.gmatch(generatedList, "([%w]+)") do
	if string.len(service) > 0 then
		services[service] = true
	end
end

local function isService(instance)
	-- avoid unnamed instances
	if instance.Name == "Instance" then
		return false
	end

	-- it shouldn't be possible to create another service
	-- prevents highest level user made instances from appearing
	-- new instance should be cleared by garbage collector
	local success = pcall(function()
		return instance.new(instance.ClassName)
	end)

	if success then
		return
	end

	return game:GetService(instance.ClassName)
end

local function checkIfService(instance)
	local success, validService = pcall(isService, instance)
	if success and validService then
		services[instance.ClassName] = true
	else
		pcall(function()
			services[instance.ClassName] = false
		end)
	end
end

game.ChildAdded:Connect(checkIfService)
game.ChildRemoved:Connect(checkIfService)
for _, v in game:GetChildren() do
	checkIfService(v)
end

return services
