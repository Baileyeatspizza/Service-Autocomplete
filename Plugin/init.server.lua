local ScriptEditorService = game:GetService("ScriptEditorService")

local Lexer = require(script.lexer)

-- service names is not ideal but causes security checks if not used so :/
local ServiceNames = {}

local PROCESS_NAME = "Service Autocomplete by Baileyeatspizza"
local LEARN_MORE_LINK = "https://create.roblox.com/docs/reference/engine/classes/"
local SERVICE_DEF = 'local %s = game:GetService("%s")\n'

local CHECKED_GLOBAL_VARIABLES = {
	print = Enum.CompletionItemKind.Function,
	_G = Enum.CompletionItemKind.Variable,
	_VERSION = Enum.CompletionItemKind.Variable,
	Vector3 = Enum.CompletionItemKind.Struct,
	CFrame = Enum.CompletionItemKind.Struct,
}

--[[
local IGNORED_TYPES = {
	keyword = true,
	comment = true,
	string = true,
}
local IGNORED_OPERATORS = {
	["."] = true,
	[":"] = true,
	["("] = false,
	[")"] = true,
}
]]

local CompletingDoc = nil
local CompleteingLine = 0
local CompleteingWordStart = 0

type Request = {
	position: {
		line: number,
		character: number,
	},
	textDocument: {
		document: ScriptDocument?,
		script: LuaSourceContainer?,
	},
}

type ResponseItem = {
	label: string,
	kind: Enum.CompletionItemKind?,
	tags: { Enum.CompletionItemTag }?,
	detail: string?,
	documentation: {
		value: string,
	}?,
	overloads: number?,
	learnMoreLink: string?,
	codeSample: string?,
	preselect: boolean?,
	textEdit: {
		newText: string,
		replace: {
			start: { line: number, character: number },
			["end"]: { line: number, character: number },
		},
	}?,
}

type Response = {
	items: {
		[number]: ResponseItem,
	},
}

type DocChanges = {
	range: { start: { line: number, character: number }, ["end"]: { line: number, character: number } },
	text: string,
}

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
		ServiceNames[instance.ClassName] = true
	else
		pcall(function()
			ServiceNames[instance.ClassName] = false
		end)
	end
end

-- used in a different function so it can return without ruining the callback
local function addServiceAutocomplete(request: Request, response: Response)
	local doc = request.textDocument.document

	local req = doc:GetLine(request.position.line)
	req = string.sub(req, 1, request.position.character - 1)

	local requestedWord = string.match(req, "[%w]+$")

	-- no text found
	if not requestedWord then
		return
	end

	local potentialMatches = {}

	for serviceName in ServiceNames do
		if string.sub(string.lower(serviceName), 1, #requestedWord) == string.lower(requestedWord) then
			potentialMatches[serviceName] = true
		end
	end

	for _, v in response.items do
		-- already exists as an autofill
		-- likely that its defined
		if potentialMatches[v.label] then
			-- append a leanMoreLink to the builtin one (this is embarassing LOL)
			v.learnMoreLink = LEARN_MORE_LINK .. v.label
			potentialMatches[v.label] = nil
		end
	end

	for serviceName in potentialMatches do
		local field: ResponseItem = {
			label = serviceName,
			detail = "Get Service: " .. serviceName,
			learnMoreLink = LEARN_MORE_LINK .. serviceName,
		}

		table.insert(response.items, field)
	end

	-- don't update if theres no matches
	if next(potentialMatches) == nil then
		return
	end

	CompletingDoc = doc
	CompleteingLine = request.position.line
	CompleteingWordStart = string.find(req, requestedWord, #req - #requestedWord)
end

local function getFullScript(doc: ScriptDocument)
	local fullScriptString = ""
	local rawSource = {}

	for line = 1, doc:GetLineCount() do
		local lineCode = doc:GetLine(line)
		if lineCode == nil then
			continue
		end

		rawSource[line] = lineCode

		lineCode ..= "\n"
		fullScriptString ..= lineCode
	end

	return fullScriptString, rawSource
end

local cachedTokens = {}
local function getAllTokens(doc: ScriptDocument)
	local fullScriptString, rawSource = getFullScript(doc)

	local cached = cachedTokens[rawSource]
	if cached then
		return cached
	end

	local currentLine = 1
	local currentCharacter = 1

	-- recursively find the tokens in order
	local function getLine(token)
		local lineCode = rawSource[currentLine]
		--print("attempting to find ", token, " in ", lineCode, " at ", currentLine, ":", currentCharacter)

		assert(lineCode, "couldn't find code to compare against")

		local tokenStart, tokenEnd = string.find(lineCode, token, currentCharacter, true)

		if tokenStart and tokenEnd then
			currentCharacter = tokenEnd + 1
			return currentLine, tokenStart, tokenEnd
		else
			currentLine += 1
			currentCharacter = 1

			return getLine(token)
		end
	end

	local quickScan = Lexer.scan(fullScriptString)
	local tokens = {}

	repeat
		local type, token = quickScan()
		if not type then
			continue
		end

		if string.match(token, "\n") then
			token = string.sub(token, 1, #token - 1)
		end

		-- sometimes needs to happen twice
		if string.match(token, "\n") then
			token = string.sub(token, 1, #token - 1)
		end

		local seperatedLines = string.split(token, "\n")
		local endLine = nil

		local line, startChar, endChar

		for _, splitToken in seperatedLines do
			if not startChar then
				line, startChar, endChar = getLine(splitToken)
				endLine = line
			else
				endLine, _, endChar = getLine(splitToken)
			end
		end

		table.insert(tokens, {
			type = type,
			value = token,
			startLine = line,
			endLine = endLine,
			startChar = startChar,
			endChar = endChar,
		})
	until not type

	cachedTokens[rawSource] = tokens
	task.delay(10, function()
		cachedTokens[rawSource] = nil
	end)

	return tokens
end

local function findNonCommentLine(doc: ScriptDocument)
	local lineAfterComments = 0

	for _, token in getAllTokens(doc) do
		if token.type ~= "comment" then
			break
		end

		lineAfterComments = token.endLine + 2
	end

	return lineAfterComments
end

local function findAllServices(doc: ScriptDocument, startLine: number?, endLine): { [string]: number }?
	startLine = startLine or 0

	local services = {
		--[ServiceName] = lineNumber
	}

	for _, token in getAllTokens(doc) do
		if token.startLine < startLine or token.endLine > endLine then
			continue
		end

		if token.type == "string" then
			local cleanValue = string.match(token.value, "%w+")
			if not ServiceNames[cleanValue] then
				continue
			end

			services[cleanValue] = token.endLine
		end
	end

	return services
end

local function processDocChanges(doc: ScriptDocument, change: DocChanges)
	if change.range.start.character ~= CompleteingWordStart and change.range.start.line ~= CompleteingLine then
		return
	end

	local serviceName = change.text

	if not ServiceNames[serviceName] or #serviceName < 3 then
		return
	end

	CompleteingLine = 0
	CompleteingWordStart = 0

	local firstServiceLine = 99999
	local lastServiceLine = 1
	local lineToComplete = 1

	local existingServices = findAllServices(doc, nil, change.range["end"].line - 1)

	if next(existingServices) then
		for otherService, line in existingServices do
			-- hit a bug where its trying to dup a service
			if otherService == serviceName then
				return
			end

			if line > lineToComplete then
				if serviceName > otherService then
					lineToComplete = line
				end

				lastServiceLine = line
			end

			if line < firstServiceLine then
				firstServiceLine = line
			end
		end

		-- caused too many problems
		for _, line in existingServices do
			if line > lastServiceLine then
				lastServiceLine = line
			end
		end

		-- hasn't changed default to the lowest
		if lineToComplete == 1 then
			lineToComplete = firstServiceLine - 1
		end

		lineToComplete += 1
		lastServiceLine += 1
	else
		lineToComplete = findNonCommentLine(doc)
		--warn("Non comment line = ", lineToComplete)
	end

	if lastServiceLine == 1 then
		lastServiceLine = lineToComplete + 1
	end

	local docLineCount = doc:GetLineCount()
	if lastServiceLine >= docLineCount then
		lastServiceLine = docLineCount
	end

	if doc:GetLine(lastServiceLine) ~= "" then
		doc:EditTextAsync("\n", lastServiceLine, 1, 0, 0)
	end

	local serviceRequire = string.format(SERVICE_DEF, serviceName, serviceName)

	--print(lineToComplete)
	if lineToComplete < 1 then
		lineToComplete = 1
	end

	doc:EditTextAsync(serviceRequire, lineToComplete, 1, 0, 0)
end

local function onDocChanged(doc: ScriptDocument, changed: { DocChanges })
	if doc:IsCommandBar() then
		return
	end

	if doc ~= CompletingDoc then
		return
	end

	for _, change in changed do
		processDocChanges(doc, change)
	end
end

local function updateResponse(request: Request, response: Response)
	--warn(#response.items)
	local isGlobalScope = false
	for _, v in response.items do
		--print(v.label, v.kind, v.preselect)

		local expectedKind = CHECKED_GLOBAL_VARIABLES[v.label]
		if expectedKind then
			if v.kind ~= expectedKind then
				continue
			end

			isGlobalScope = true
			break
		end
	end

	if not isGlobalScope then
		--warn("Couldn't find global variables")
		return
	end

	--[[
	local targetLine = request.position.line
	local targetCharacter = request.position.character

	local tokens = getAllTokens(doc)
	local closestToken = tokens[1]
	local secondClosest = tokens[1]

	for _, v in getAllTokens(doc) do
		if v.type == "iden" then
			continue
		end

		if v.startLine <= targetLine then
			if v.startLine == closestToken.startLine then
				if v.startChar > closestToken.startChar and v.startChar < targetCharacter then
					if v.type == "operator" then
						if string.find(v.value, ",") then
							continue
						end
					end

					secondClosest = closestToken
					closestToken = v
				end
				continue
			end
			closestToken = v
		else
			break
		end
	end

	--warn(closestToken)

	-- assume there aren't any problems if the last token is on a seperate line
	if not (closestToken.endLine < targetLine) then
		if closestToken.type == "operator" then
			if closestToken.value == "(" and secondClosest.type == "keyword" then
				if string.find(secondClosest.value, "function") then
					return response
				end
			end

			if IGNORED_OPERATORS[closestToken.value] then
				return response
			end
		elseif IGNORED_TYPES[closestToken.type] then
			return response
		end
	end
	]]

	CompleteingLine = 0
	CompleteingWordStart = 0
	addServiceAutocomplete(request, response)
end

local function completionRequested(request: Request, response: Response)
	local doc = request.textDocument.document
	-- can't write to the command bar sadly ;C
	if doc == nil or doc:IsCommandBar() then
		return response
	end

	-- shares the response to another function
	-- prevents the error where response isn't returned
	updateResponse(request, response)

	return response
end

-- prevent potential overlap for some reason errors if one doesn't exist weird api choice but ok-
pcall(ScriptEditorService.DeregisterAutocompleteCallback, ScriptEditorService, PROCESS_NAME)
ScriptEditorService:RegisterAutocompleteCallback(PROCESS_NAME, 99, completionRequested)

local outputted = false
while true do
	local success, err = pcall(function()
		ScriptEditorService.TextDocumentDidChange:Connect(onDocChanged)
	end)

	if success then
		break
	end

	if not outputted then
		if string.match(err, "denied script") then
			warn("Script injection permissions are needed for the plugin to run please enable them in settings")
			outputted = true
		end
	end

	task.wait(1)
end

game.ChildAdded:Connect(checkIfService)
game.ChildRemoved:Connect(checkIfService)
for _, v in game:GetChildren() do
	checkIfService(v)
end
