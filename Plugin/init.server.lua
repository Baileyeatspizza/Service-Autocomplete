local ScriptEditorService = game:GetService("ScriptEditorService")

local Lexer = require(script.lexer)

-- service names is not ideal but causes security checks if not used so :/
local ServiceNames = {}

local CompletingDoc = nil
local CompleteingLine = 0
local CompleteingWordStart = 0

local PROCESSNAME = "Baileyeatspizza - Autocomplete Services"
local SINGLELINECOMMENT = "%-%-"
local COMMENTBLOCKSTART = "%-%-%[%["
local COMMENTBLOCKEND = "%]%]"
local LEARNMORELINK = "https://create.roblox.com/docs/reference/engine/classes/"
local SERVICEDEF = 'local %s = game:GetService("%s")\n'

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

local function warnLog(message)
	warn("[Service Autofill] - " .. message)
end

local function isService(instance)
	-- not adding workspace due to the builtin globals
	if instance.ClassName == "Workspace" then
		return false
	end

	-- avoid unnamed instances
	if instance.Name == "Instance" then
		return false
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

-- strings are irritating due to the three potential definitions
-- for performance if it looks close enough like the autofil is within the strings
-- it will just cancel out
-- Not accounting for multi line strings due to performance and how little they are used
local function backTraceStrings(doc: ScriptDocument, line: number, char: number)
	return false
end

local function backTraceComments(doc: ScriptDocument, line: number, char: number): boolean
	local startLine = doc:GetLine(line)
	local lineCount = doc:GetLineCount()

	-- single line comment blocks
	if string.find(startLine, COMMENTBLOCKSTART) then
		local commentBlockEnd = string.find(startLine, COMMENTBLOCKEND)

		if not commentBlockEnd or commentBlockEnd >= char then
			return true
		end
	elseif string.match(startLine, SINGLELINECOMMENT) then
		return true
	end

	-- exception if the comment block end is at the start of the line?
	local exceptionCase = string.find(startLine, COMMENTBLOCKEND)
	if exceptionCase and char >= exceptionCase then
		return false
	end

	local blockStart = nil
	local blockStartLine = nil
	local blockEnd = nil
	local blockEndLine = nil

	for i = line, 1, -1 do
		local currentLine = doc:GetLine(i)

		blockStart = string.find(currentLine, COMMENTBLOCKSTART)

		if blockStart then
			local sameLineBlockEnd = string.find(currentLine, COMMENTBLOCKEND)

			if sameLineBlockEnd then
				return false
			end
			blockStartLine = i

			-- do a quick search forward to find it

			for l = i + 1, lineCount do
				local nextLine = doc:GetLine(l)

				blockEnd = string.find(nextLine, COMMENTBLOCKEND)

				if blockEnd then
					blockEndLine = l
					break
				end
			end

			break
		end
	end

	if not blockStart or not blockEnd then
		return false
	end

	if line > blockStartLine and line <= blockEndLine then
		return true
	end

	return false
end

local function hasBackTraces(doc, line, char)
	if backTraceComments(doc, line, char) then
		return true
	end
	if backTraceStrings(doc, line, char) then
		return true
	end

	return false
end

-- used in a different function so it can return without ruining the callback
local function addServiceAutocomplete(request: Request, response: Response)
	local doc = request.textDocument.document

	if hasBackTraces(doc, request.position.line, request.position.character) then
		return
	end

	local req = doc:GetLine(request.position.line)

	req = string.sub(req, 1, request.position.character - 1)

	local requestedWord = string.match(req, "[%w]+$")

	local statementStart, variableStatement = string.find(req, "local " .. (requestedWord or ""))

	if variableStatement and #string.sub(req, statementStart, variableStatement) >= #req then
		return
	end

	-- no text found
	if requestedWord == nil then
		return
	end

	local beforeRequest = string.sub(req, 1, #req - #requestedWord)

	if string.sub(beforeRequest, #beforeRequest, #beforeRequest) == "." then
		return
	end

	-- TODO: improve with better string checks
	if string.match(beforeRequest, "'") or string.match(beforeRequest, '"') then
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
			v.learnMoreLink = LEARNMORELINK .. v.label
			potentialMatches[v.label] = nil
		end
	end

	for serviceName in potentialMatches do
		local field: ResponseItem = {
			label = serviceName,
			detail = "Get Service " .. serviceName,
			learnMoreLink = LEARNMORELINK .. serviceName,
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

local function completionRequested(request: Request, response: Response)
	local doc = request.textDocument.document
	-- can't write to the command bar sadly ;C
	if doc == nil or doc:IsCommandBar() then
		return response
	end

	CompleteingLine = 0
	CompleteingWordStart = 0
	addServiceAutocomplete(request, response)

	return response
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

	print(rawSource)

	local currentLine = 1
	local currentCharacter = 1

	-- recursively find the tokens in order
	local function getLine(token)
		local lineCode = rawSource[currentLine]
		print("attempting to find ", token, " in ", lineCode, " at ", currentLine, ":", currentCharacter)

		assert(lineCode, "couldn't find code to compare against")

		print(
			string.find(
				'--- ReplicatedStorage = game:GetService("ReplicatedStorage")',
				'--- ReplicatedStorage = game:GetService("ReplicatedStorage")'
			)
		)

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

		local line, startChar, endChar = getLine(token)

		table.insert(tokens, {
			type = type,
			token = token,
			line = line,
			startChar = startChar,
			endChar = endChar,
		})
	until not type

	return fullScriptString, tokens
end

--[[
local function findNonCommentLine(doc: ScriptDocument)
	local scriptString, tokens = getAllTokens(doc)

	local ModifiedScriptString = scriptString

	for _, v in tokens do
		print(v)
		if v.type ~= "comment" then
			break
		end

		local _, endOfToken = string.find(ModifiedScriptString, v.token, 1, true)

		warn(endOfToken)

		if endOfToken then
			ModifiedScriptString = string.sub(ModifiedScriptString, endOfToken)
			print(ModifiedScriptString)
		else
			warn("couldn't find ", endOfToken)
		end
	end

	print(ModifiedScriptString)

	-- eliminates the last whitespace from the query
	local oldLineCount = #string.split(scriptString, "\n")
	local newLineCount = #string.split(ModifiedScriptString, "\n")

	print(oldLineCount, newLineCount)

	return (oldLineCount - newLineCount)
end
]]

-- using this over the lexer version to easily identify the first line with just whitespace
local function findNonCommentLine(doc: ScriptDocument)
	local lineAfterComments = 0
	local comments = true

	local lineCount = doc:GetLineCount()

	for _, token in getAllTokens() do
		if token.type ~= "comment" then
			comments = false
			break
		end

		lineAfterComments += 1
	end

	return lineAfterComments + 1
end

local function findAllServices(doc: ScriptDocument, startLine: number?, endLine): { [string]: number }?
	print(getAllTokens(doc))

	startLine = startLine or 1

	-- we don't account for duplicate services
	-- that is user error if it occurs
	local services = {
		--[ServiceName] = lineNumber
	}

	for i = startLine :: number, endLine do
		local line = doc:GetLine(i)
		local match = string.match(line, ":GetService%([%C]+")

		if match then
			local closingParenthesis = string.find(match, "%)")
			match = string.sub(match, 14, closingParenthesis - 2)

			services[match] = i
		end
	end

	if next(services) then
		return services
	end

	return {}
end

local function processDocChanges(doc: ScriptDocument, change: DocChanges)
	if change.range.start.character ~= CompleteingWordStart and change.range.start.line ~= CompleteingLine then
		return
	end

	local serviceName = change.text

	if not ServiceNames[serviceName] or #serviceName < 3 then
		return
	end

	-- for some reason studio ignored the variable on the top line so exit if it exists
	local firstLineService = doc:GetLine(1)
	local topService = string.match(firstLineService, "%w+", 6)
	if serviceName == topService then
		return
	end

	CompleteingLine = 0
	CompleteingWordStart = 0

	local firstServiceLine = 99999
	local lastServiceLine = 1
	local lineToComplete = 1

	local existingServices = findAllServices(doc, nil, change.range["end"].line)
	if next(existingServices) then
		for otherService, line in existingServices do
			if line > lineToComplete then
				if serviceName > otherService then
					lineToComplete = line
				end

				-- hit a bug where its trying to dup a service
				if otherService == serviceName then
					return
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
		warn("Non comment line = ", lineToComplete)
	end

	if lastServiceLine == 1 then
		lastServiceLine = lineToComplete + 1
	end

	if lastServiceLine >= doc:GetLineCount() then
		lastServiceLine = doc:GetLineCount()
	end

	if doc:GetLine(lastServiceLine) ~= "" then
		doc:EditTextAsync("\n", lastServiceLine, 1, 0, 0)
	end

	local serviceRequire = string.format(SERVICEDEF, serviceName, serviceName)
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

-- prevent potential overlap for some reason errors if one doesn't exist weird api choice but ok-
pcall(function()
	ScriptEditorService:DeregisterAutocompleteCallback(PROCESSNAME)
end)
ScriptEditorService:RegisterAutocompleteCallback(PROCESSNAME, 69, completionRequested)
ScriptEditorService.TextDocumentDidChange:Connect(onDocChanged)

game.ChildAdded:Connect(checkIfService)
game.ChildRemoved:Connect(checkIfService)
for _, v in game:GetChildren() do
	checkIfService(v)
end
