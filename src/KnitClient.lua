--[=[
	@interface Middleware
	.Inbound ClientMiddleware?
	.Outbound ClientMiddleware?
	@within KnitClient
]=]
type Middleware = {
	Inbound: ClientMiddleware?,
	Outbound: ClientMiddleware?,
}

--[=[
	@type ClientMiddlewareFn (args: {any}) -> (shouldContinue: boolean, ...: any)
	@within KnitClient

	For more info, see [ClientComm](https://sleitnick.github.io/RbxUtil/api/ClientComm/) documentation.
]=]
type ClientMiddlewareFn = (args: {any}) -> (boolean, ...any)

--[=[
	@type ClientMiddleware {ClientMiddlewareFn}
	@within KnitClient
	An array of client middleware functions.
]=]
type ClientMiddleware = {ClientMiddlewareFn}

--[=[
	@type PerServiceMiddleware {[string]: Middleware}
	@within KnitClient
]=]
type PerServiceMiddleware = {[string]: Middleware}

--[=[
	@interface ControllerDef
	.Name string
	.[any] any
	@within KnitClient
	Used to define a controller when creating it in `CreateController`.
]=]
type ControllerDef = {
	Name: string,
	[any]: any,
}

--[=[
	@interface Controller
	.Name string
	.[any] any
	@within KnitClient
]=]
type Controller = {
	Name: string,
	[any]: any,
}

--[=[
	@interface Component
	.Tag string
	.[any] any
	@within KnitClient
]=]

type Component = {
	Tag: string,
	[any]: any,
}

--[=[
	@interface Service
	.[any] any
	@within KnitClient
]=]
type Service = {
	[any]: any,
}

type ParallelInterface = {
	[any]: any
}

--[=[
	@interface KnitOptions
	.ServicePromises boolean?
	.Middleware Middleware?
	.PerServiceMiddleware PerServiceMiddleware?
	@within KnitClient

	- `ServicePromises` defaults to `true` and indicates if service methods use promises.
	- Each service will go through the defined middleware, unless the service
	has middleware defined in `PerServiceMiddleware`.
]=]
type KnitOptions = {
	ServicePromises: boolean,
	Middleware: Middleware?,
	PerServiceMiddleware: PerServiceMiddleware?,
}

local defaultOptions: KnitOptions = {
	ServicePromises = true,
	Middleware = nil,
	PerServiceMiddleware = {},
}

local selectedOptions = nil


--[=[
	@class KnitClient
	@client
]=]
local KnitClient = {}

--[=[
	@prop Player Player
	@within KnitClient
	@readonly
	Reference to the LocalPlayer.
]=]
KnitClient.Player = game:GetService("Players").LocalPlayer

--[=[
	@prop Util Folder
	@within KnitClient
	@readonly
	References the Util folder. Should only be accessed when using Knit as
	a standalone module. If using Knit from Wally, modules should just be
	pulled in via Wally instead of relying on Knit's Util folder, as this
	folder only contains what is necessary for Knit to run in Wally mode.
]=]
KnitClient.Util = script.Parent.Parent

local Promise = require(KnitClient.Util.Promise)
local Comm = require(KnitClient.Util.Comm)
local ParallelComm = script.Parent.ParallelComm
local ClientComm = Comm.ClientComm
local ParallelClientComm = ParallelComm.ParallelClientComm

local controllers: {[string]: Controller} = {}
local services: {[string]: Service} = {}
local servicesFolder = nil
local actorsFolder = Instance.new("Folder")
actorsFolder.Name = "ParallelActors"
actorsFolder.Parent = script.Parent

local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

local AcceptableTypes = { "string", "number", "boolean", "Enum" }
local UIDGen = 0



local function DoesControllerExist(controllerName: string): boolean
	local controller: Controller? = controllers[controllerName]
	return controller ~= nil
end


local function GetServicesFolder()
	if not servicesFolder then
		servicesFolder = script.Parent:WaitForChild("Services")
	end
	return servicesFolder
end


local function GetMiddlewareForService(serviceName: string)
	local knitMiddleware = selectedOptions.Middleware or {}
	local serviceMiddleware = selectedOptions.PerServiceMiddleware[serviceName]
	return serviceMiddleware or knitMiddleware
end


local function BuildService(serviceName: string)
	local folder = GetServicesFolder()
	local middleware = GetMiddlewareForService(serviceName)
	local clientComm = ClientComm.new(folder, selectedOptions.ServicePromises, serviceName)
	local service = clientComm:BuildObject(middleware.Inbound, middleware.Outbound)
	services[serviceName] = service
	return service
end


--[=[
	Creates a new controller.

	:::caution
	Controllers must be created _before_ calling `Knit.Start()`.
	:::
	```lua
	-- Create a controller
	local MyController = Knit.CreateController {
		Name = "MyController",
	}

	function MyController:KnitStart()
		print("MyController started")
	end

	function MyController:KnitInit()
		print("MyController initialized")
	end
	```
]=]
function KnitClient.CreateController(controllerDef: ControllerDef): Controller
	assert(type(controllerDef) == "table", "Controller must be a table; got " .. type(controllerDef))
	assert(type(controllerDef.Name) == "string", "Controller.Name must be a string; got " .. type(controllerDef.Name))
	assert(#controllerDef.Name > 0, "Controller.Name must be a non-empty string")
	assert(not DoesControllerExist(controllerDef.Name), "Controller \"" .. controllerDef.Name .. "\" already exists")
	local controller = controllerDef :: Controller
	controllers[controller.Name] = controller
	return controller
end


--[=[
	Requires all the modules that are children of the given parent. This is an easy
	way to quickly load all controllers that might be in a folder.
	```lua
	Knit.AddControllers(somewhere.Controllers)
	```
]=]
function KnitClient.AddControllers(parent: Instance): {Controller}
	local addedControllers = {}
	for _,v in ipairs(parent:GetChildren()) do
		if not v:IsA("ModuleScript") then continue end
		table.insert(addedControllers, require(v))
	end
	return addedControllers
end


--[=[
	Requires all the modules that are descendants of the given parent.
]=]
function KnitClient.AddControllersDeep(parent: Instance): {Controller}
	local addedControllers = {}
	for _,v in ipairs(parent:GetDescendants()) do
		if not v:IsA("ModuleScript") then continue end
		table.insert(addedControllers, require(v))
	end
	return addedControllers
end

function KnitClient.AddComponents(parent: Instance): {Component}
	local addedComponents = {}

	for _,v in ipairs(parent:GetDescendants()) do
		if not v:IsA("ModuleScript") then continue end
		table.insert(addedComponents, require(v))
	end

	return addedComponents
end

--[=[
	Returns a Service object which is a reflection of the remote objects
	within the Client table of the given service. Throws an error if the
	service is not found.

	If a service's Client table contains RemoteSignals and/or RemoteProperties,
	these values are reflected as
	[ClientRemoteSignals](https://sleitnick.github.io/RbxUtil/api/ClientRemoteSignal) and
	[ClientRemoteProperties](https://sleitnick.github.io/RbxUtil/api/ClientRemoteProperty).

	```lua
	-- Server-side service creation:
	local MyService = Knit.CreateService {
		Name = "MyService",
		Client = {
			MySignal = Knit.CreateSignal(),
			MyProperty = Knit.CreateProperty("Hello"),
		},
	}
	function MyService:AddOne(player, number)
		return number + 1
	end

	-------------------------------------------------

	-- Client-side service reflection:
	local MyService = Knit.GetService("MyService")

	-- Call a method:
	local num = MyService:AddOne(5) --> 6

	-- Fire a signal to the server:
	MyService.MySignal:Fire("Hello")

	-- Listen for signals from the server:
	MyService.MySignal:Connect(function(message)
		print(message)
	end)

	-- Observe the initial value and changes to properties:
	MyService.MyProperty:Observe(function(value)
		print(value)
	end)
	```

	:::caution
	Services are only exposed to the client if the service has remote-based
	content in the Client table. If not, the service will not be visible
	to the client. `KnitClient.GetService` will only work on services that
	expose remote-based content on their Client tables.
	:::
]=]
function KnitClient.GetService(serviceName: string): Service
	local service = services[serviceName]
	if service then
		return service
	end
	assert(started, "Cannot call GetService until Knit has been started")
	assert(type(serviceName) == "string", "ServiceName must be a string; got " .. type(serviceName))
	return BuildService(serviceName)
end


--[=[
	Gets the controller by name. Throws an error if the controller
	is not found.
]=]
function KnitClient.GetController(controllerName: string): Controller
	local controller = controllers[controllerName]
	if controller then
		return controller
	end
	assert(started, "Cannot call GetController until Knit has been started")
	assert(type(controllerName) == "string", "ControllerName must be a string; got " .. type(controllerName))
	error("Could not find controller \"" .. controllerName .. "\". Check to verify a controller with this name exists.", 2)
end


--[[

	Module.Start

	Actor
	-- Actor.Start() --> Fire Bindable --> return whatever Start has
	{__call}

	Module;
	loop through module


	Module.Tick = 12434
	Module.Blah = true


	Module.Function = function()

	end


	__newindex

	variable exists in {}
	Invoke a bindable return value

	Actor.Tick --> InvokeBindable
	
	Actor.Function

	return function(self,...)
		Bindable:Fire(...)
	end


	Actor:RunFunction("gredgerg")
	Actor:GetVariable("wegrg)
	
]]

local function NewUID()
	UIDGen += 1
	return UIDGen
end

function KnitClient.LoadParallel(Module : ModuleScript): ParallelInterface

	local Actor = Instance.new("Actor")
	local ActorCommScript = ParallelClientComm:Clone()
	ActorCommScript.Parent = Actor

	local ActorCommEvent = ActorCommScript.CommEvent
	local ActorCommFunction = ActorCommScript.CommFunction

	local SymbolsTable = {}

	--[[
		if doesn't exist in SymbolsTable
		we pass {value = tbl, __type = "Symbol"}
		{value = object, __type = "Symbol"}

		HttpService:GenerateGUID
		Actor[player] = "something"
		{value = player, _id = "TableA", _type = "Symbol"}

		in interface
		if typeof(value) == table and value._type == "Symbol
	]]

	local function BuildSymbol(value)
		local ID = NewUID()
		SymbolsTable[value] = ID
		return {_id = ID, _type = "symbol", value = value }
	end

	local Interface = setmetatable({},{
		__index = function(_,index : any)
			if index == nil then error("Attempt to index table with nil value", 3) end

			local SerializedIndex = index
			if not table.find(AcceptableTypes, typeof(index)) then SerializedIndex = SymbolsTable[index] or BuildSymbol(index) end

			local IndexValue = ActorCommFunction:Invoke("GetIndex",SerializedIndex)

			if typeof(IndexValue) == "table" and IndexValue._type == "function" then
				return function(...)
					return ActorCommFunction:Invoke("CallFunction",IndexValue.path,...)
				end
			elseif typeof(IndexValue) == "table" and IndexValue._type == "symbol" then
				return IndexValue.value
			else
				return IndexValue
			end
		end,
		__newindex = function(_,index : any, value : any)
			if index == nil then error("Attempt to index table with nil value", 3) end

			local SerializedIndex = index
			if not table.find(AcceptableTypes, typeof(index)) then SerializedIndex = SymbolsTable[index] or BuildSymbol(index) end
			if value == nil then SymbolsTable[index] = nil end
			
			--//TODO: Add function serialization using the below API:
			--[[
				if it's a module
				Actor.Start = Actor:SerializeFunction(module, "Run")
				
				{
					module = ModuleScript,
					path = "Start",
					_type = "function"
				}
			]]
			ActorCommEvent:Fire("SetIndex",SerializedIndex,value)
		end
	})

	Actor.Parent = actorsFolder
	task.defer(function()
		ActorCommScript.Enabled = true
	end)

	local InitReply
	repeat
		InitReply = ActorCommEvent.Event:Wait()
	until InitReply == "Initialized"

	ActorCommEvent:Fire("LoadModule",Module)
	
	return Interface :: ParallelInterface
end


--[=[
	@return Promise
	Starts Knit. Should only be called once per client.
	```lua
	Knit.Start():andThen(function()
		print("Knit started!")
	end):catch(warn)
	```

	By default, service methods exposed to the client will return promises.
	To change this behavior, set the `ServicePromises` option to `false`:
	```lua
	Knit.Start({ServicePromises = false}):andThen(function()
		print("Knit started!")
	end):catch(warn)
	```
]=]
function KnitClient.Start(options: KnitOptions?)

	if started then
		return Promise.reject("Knit already started")
	end

	started = true

	if options == nil then
		selectedOptions = defaultOptions
	else
		assert(typeof(options) == "table", "KnitOptions should be a table or nil; got " .. typeof(options))
		selectedOptions = options
		for k,v in pairs(defaultOptions) do
			if selectedOptions[k] == nil then
				selectedOptions[k] = v
			end
		end
	end
	if type(selectedOptions.PerServiceMiddleware) ~= "table" then
		selectedOptions.PerServiceMiddleware = {}
	end

	return Promise.new(function(resolve)

		-- Init:
		local promisesStartControllers = {}

		for _,controller in pairs(controllers) do
			if type(controller.KnitInit) == "function" then
				table.insert(promisesStartControllers, Promise.new(function(r)
					debug.setmemorycategory(controller.Name)
					controller:KnitInit()
					r()
				end))
			end
		end

		resolve(Promise.all(promisesStartControllers))

	end):andThen(function()

		-- Start:
		for _,controller in pairs(controllers) do
			if type(controller.KnitStart) == "function" then
				task.spawn(function()
					debug.setmemorycategory(controller.Name)
					controller:KnitStart()
				end)
			end
		end

		startedComplete = true
		onStartedComplete:Fire()

		task.defer(function()
			onStartedComplete:Destroy()
		end)

	end)

end


--[=[
	@return Promise
	Returns a promise that is resolved once Knit has started. This is useful
	for any code that needs to tie into Knit controllers but is not the script
	that called `Start`.
	```lua
	Knit.OnStart():andThen(function()
		local MyController = Knit.GetController("MyController")
		MyController:DoSomething()
	end):catch(warn)
	```
]=]
function KnitClient.OnStart()
	if startedComplete then
		return Promise.resolve()
	else
		return Promise.fromEvent(onStartedComplete.Event)
	end
end


return KnitClient
