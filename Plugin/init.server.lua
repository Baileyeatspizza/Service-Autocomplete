local ScriptEditorService = game:GetService("ScriptEditorService")

local Lexer = require(script.lexer)
local Settings = require(script.Settings)(plugin)
local ServiceNames = require(script.Services)

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
		local responseItem: ResponseItem = {
			label = serviceName,
			detail = "Get Service: " .. serviceName,
			learnMoreLink = LEARN_MORE_LINK .. serviceName,
		}

		responseItem.textEdit = {
			newText = serviceName,
			replace = {
				start = {
					line = request.position.line,
					character = request.position.character - #requestedWord,
				},
				["end"] = {
					line = request.position.line,
					character = request.position.character,
				},
			},
		}

		table.insert(response.items, responseItem)
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

local function getAllTokens(doc: ScriptDocument)
	local fullScriptString, rawSource = getFullScript(doc)

	local currentLine = 1
	local currentCharacter = 1

	-- recursively find the tokens in order
	local function getLine(token)
		local lineCode = rawSource[currentLine]
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

local function findAllServices(doc: ScriptDocument, startLine: number, endLine: number): { [string]: number }?
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

	local firstServiceLine = math.huge
	local lastServiceLine = 1
	local lineToComplete = 1
	local moved = false

	local existingServices = findAllServices(doc, 0, change.range["end"].line - 1)

	if next(existingServices) then
		for otherService, line in existingServices do
			-- hit a bug where its trying to duplicate a service
			if otherService == serviceName then
				return
			end

			if line >= lineToComplete then
				-- sorting operator
				if Settings:CompareServices(serviceName, otherService) then
					lineToComplete = line
					moved = true
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
		if lineToComplete == 1 and not moved then
			lineToComplete = firstServiceLine - 1
		end

		lineToComplete += 1
		lastServiceLine += 1
	else
		lineToComplete = findNonCommentLine(doc)
	end

	if lastServiceLine == 1 then
		lastServiceLine += 1
	end

	local docLineCount = doc:GetLineCount()
	if lastServiceLine >= docLineCount then
		lastServiceLine = docLineCount
	end

	if doc:GetLine(lastServiceLine) ~= "" then
		doc:EditTextAsync("\n", lastServiceLine, 1, 0, 0)
	end

	if lineToComplete < 1 then
		lineToComplete = 1
	end

	local serviceRequire = string.format(SERVICE_DEF, serviceName, serviceName)
	doc:EditTextAsync(serviceRequire, lineToComplete, 1, 0, 0)
end

pcall(ScriptEditorService.DeregisterAutocompleteCallback, ScriptEditorService, PROCESS_NAME)
ScriptEditorService:RegisterAutocompleteCallback(PROCESS_NAME, 10, function(request: Request, response: Response)
	local doc = request.textDocument.document
	if not doc or doc:IsCommandBar() then
		return response
	end

	for _, v in response.items do
		local expectedKind = CHECKED_GLOBAL_VARIABLES[v.label]
		if expectedKind then
			if v.kind ~= expectedKind then
				continue
			end

			CompleteingLine = 0
			CompleteingWordStart = 0
			addServiceAutocomplete(request, response)
			break
		end
	end

	return response
end)

-- roblox will throw an output error and tell the user to enable script injection in settings if this fails to connect
ScriptEditorService.TextDocumentDidChange:Connect(function(document: ScriptDocument, changesArray: { DocChanges })
	if document:IsCommandBar() or document ~= CompletingDoc then
		return
	end

	for _, change in changesArray do
		processDocChanges(document, change)
	end
end)

plugin.Unloading:Connect(function()
	pcall(ScriptEditorService.DeregisterAutocompleteCallback, ScriptEditorService, PROCESS_NAME)
end)
