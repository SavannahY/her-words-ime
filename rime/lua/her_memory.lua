-- Local word memory. Lua alone writes learned.tsv; management tools alone write
-- policy.tsv. Nothing reads surrounding application text or sends data online.
local M = {}
local MAX_WORDS = 2000
local HEADER = "HER_WORD_MEMORY\t1"

local function lower(text)
  return (text:gsub("[A-Z]", function(char) return string.char(char:byte() + 32) end))
end
local function clean_word(text)
  if type(text) ~= "string" or text == "" or #text > 128 or text:find("[/:@]") then return false end
  local length = utf8.len(text)
  if not length or length > 32 then return false end
  for _, char in ipairs({ "，", "。", "？", "！", "；", "、", "（", "）", "【", "】" }) do
    if text:find(char, 1, true) then return false end
  end
  for _, codepoint in utf8.codes(text) do
    if codepoint <= 0x20 or codepoint == 0x7F or codepoint == 0x85 or codepoint == 0xA0 or codepoint == 0x1680
        or (codepoint >= 0x2000 and codepoint <= 0x200A) or codepoint == 0x2028
        or codepoint == 0x2029 or codepoint == 0x202F or codepoint == 0x205F
        or codepoint == 0x3000 then return false end
  end
  return true
end
local function clean_input(text)
  if type(text) ~= "string" then return nil end
  text = lower(text):gsub("[%s']", "")
  if text == "" or #text > 128 or text:find("[^a-z]") then return nil end
  return text
end
local function fields(line)
  local result = {}
  for item in (line .. "\t"):gmatch("([^\t]*)\t") do result[#result + 1] = item end
  return result
end
local function integer(text)
  if type(text) ~= "string" or #text < 1 or #text > 12 or text:find("[^0-9]") then return nil end
  return tonumber(text)
end
local function load_lines(path)
  local file, _, code = io.open(path, "r")
  if not file then
    if code == 2 then return {}, true end
    return nil, false
  end
  if file:read("*l") ~= HEADER then file:close(); return nil, false end
  local lines = {}
  for line in file:lines() do
    if #lines >= MAX_WORDS * 4 + 2 or #line > 512 then file:close(); return nil, false end
    if line ~= "" then lines[#lines + 1] = fields(line) end
  end
  file:close()
  return lines, true
end
local function policy(path)
  local rows, ok = load_lines(path)
  if not ok then return nil end
  local result = { learning = true, clear_before = 0, manual = {}, blocked = {}, forgotten = {} }
  local seen = {}
  local counts = { M = 0, B = 0, F = 0 }
  for _, row in ipairs(rows) do
    local identity = (row[1] or "") .. "\0" .. (row[2] or "")
    if row[1] == "S" and row[2] == "learning" and #row == 3 and (row[3] == "0" or row[3] == "1") then
      result.learning = row[3] == "1"
    elseif row[1] == "S" and row[2] == "clear_before" and #row == 3 and integer(row[3]) then
      result.clear_before = integer(row[3])
    elseif row[1] == "M" and #row == 4 and clean_input(row[2]) == row[2] and clean_word(row[3]) and integer(row[4]) then
      identity = "M\0" .. row[2] .. "\0" .. lower(row[3])
      result.manual[#result.manual + 1] = { input = row[2], text = row[3], count = 1, last = integer(row[4]), manual = true }
    elseif (row[1] == "B" or row[1] == "F") and #row == 3 and clean_word(row[2]) and integer(row[3]) then
      local target = row[1] == "B" and result.blocked or result.forgotten
      identity = row[1] .. "\0" .. lower(row[2])
      target[lower(row[2])] = integer(row[3])
    else return nil end
    if seen[identity] then return nil end
    seen[identity] = true
    if counts[row[1]] then
      counts[row[1]] = counts[row[1]] + 1
      if counts[row[1]] > MAX_WORDS then return nil end
    end
  end
  return result
end
local function blocked(text, current)
  local folded = lower(text)
  for term, _ in pairs(current.blocked) do
    local ascii = true
    for index = 1, #term do if term:byte(index) > 127 then ascii = false; break end end
    local begin_at = 1
    while true do
      local first, last = folded:find(term, begin_at, true)
      if not first then break end
      if not ascii then return true end
      local before, after = folded:sub(first - 1, first - 1), folded:sub(last + 1, last + 1)
      if (first == 1 or not before:find("[a-zA-Z0-9_]")) and (after == "" or not after:find("[a-zA-Z0-9_]")) then return true end
      begin_at = last + 1
    end
  end
  return false
end
local function load_learned(path)
  local rows, ok = load_lines(path)
  if not ok then return nil end
  local result = {}
  local count = 0
  for _, row in ipairs(rows) do
    if row[1] ~= "L" or #row ~= 5 or clean_input(row[2]) ~= row[2] or not clean_word(row[3])
        or not integer(row[4]) or integer(row[4]) < 1 or integer(row[4]) > 1000000 or not integer(row[5]) then return nil end
    local identity = row[2] .. "\0" .. lower(row[3])
    if result[identity] then return nil end
    result[identity] = { input = row[2], text = row[3], count = integer(row[4]), last = integer(row[5]) }
    count = count + 1
    if count > MAX_WORDS then return nil end
  end
  return result
end
local function save_learned(path, learned)
  local ordered = {}
  for _, word in pairs(learned) do ordered[#ordered + 1] = word end
  table.sort(ordered, function(a, b)
    if a.last ~= b.last then return a.last > b.last end
    if a.count ~= b.count then return a.count > b.count end
    return a.text < b.text
  end)
  local temporary = path .. ".tmp"
  local file = io.open(temporary, "w")
  if not file then return false end
  file:write(HEADER .. "\n")
  for index, word in ipairs(ordered) do
    if index > MAX_WORDS then break end
    file:write("L\t", word.input, "\t", word.text, "\t", tostring(word.count), "\t", tostring(word.last), "\n")
  end
  local ok = file:close()
  if not ok then os.remove(temporary); return false end
  return os.rename(temporary, path) and true or false
end
function M.refresh(env)
  local current = policy(env.her_memory_policy)
  if not current then
    env.her_memory_policy_valid = false
    env.engine.context:set_property("her_memory_error", "本地词库配置损坏，未更新记忆")
    return env.her_memory_current -- retain the last valid block rules
  end
  env.her_memory_policy_valid = true
  env.her_memory_current = current
  local learned = load_learned(env.her_memory_learned)
  if not learned then
    env.her_memory_learned_valid = false
    env.engine.context:set_property("her_memory_error", "本地记忆文件损坏，未覆盖原文件")
    env.her_memory_words = {}
    return current
  end
  env.her_memory_learned_valid = true
  local changed = false
  for key, word in pairs(learned) do
    local cutoff = math.max(current.clear_before, current.forgotten[lower(word.text)] or 0)
    if word.last <= cutoff or blocked(word.text, current) then learned[key] = nil; changed = true end
  end
  if changed and not save_learned(env.her_memory_learned, learned) then
    env.engine.context:set_property("her_memory_error", "本地词库无法写入")
  else env.engine.context:set_property("her_memory_error", "") end
  env.her_memory_words = learned
  return current
end
function M.is_blocked(env, text)
  if env.her_memory_policy_valid == false and not env.her_memory_current then return true end
  return env.her_memory_current and blocked(text, env.her_memory_current) or false
end
function M.suggestions(env, input)
  local current = env.her_memory_current
  if not current then return {} end
  local matches, seen = {}, {}
  local function add(word)
    if word.input == input and not blocked(word.text, current) and not seen[word.text] then
      seen[word.text] = true
      matches[#matches + 1] = word
    end
  end
  for _, word in ipairs(current.manual) do add(word) end
  local learned = {}
  for _, word in pairs(env.her_memory_words or {}) do learned[#learned + 1] = word end
  table.sort(learned, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.last ~= b.last then return a.last > b.last end
    return a.text < b.text
  end)
  for _, word in ipairs(learned) do add(word) end
  return matches
end
function M.init(env)
  local directory = rime_api.get_user_data_dir()
  env.her_memory_policy = directory .. "/her_memory_policy.tsv"
  env.her_memory_learned = directory .. "/her_memory_learned.tsv"
  M.refresh(env)
  env.her_memory_connection = env.engine.context.commit_notifier:connect(function(context)
    local current = M.refresh(env)
    if not current or not current.learning or not env.her_memory_words
        or not env.her_memory_policy_valid or not env.her_memory_learned_valid then return end
    local candidate = context:get_selected_candidate()
    if not candidate or candidate.type == "her_priority" or candidate.type == "her_friendly_alias"
        or (candidate.comment or ""):find("友好表达", 1, true) or (candidate.comment or ""):find("社群写法", 1, true) then return end
    local text, input = context:get_commit_text(), clean_input(context.input)
    if not input or not clean_word(text) or blocked(text, current) then return end
    -- One-character commits are ordinary character composition, not a name.
    if utf8.len(text) < 2 then return end
    local now = os.time()
    local key = input .. "\0" .. lower(text)
    local previous = env.her_memory_words[key]
    env.her_memory_words[key] = { input = input, text = text,
      count = math.min(1000000, (previous and previous.count or 0) + 1), last = now }
    if not save_learned(env.her_memory_learned, env.her_memory_words) then
      context:set_property("her_memory_error", "本地词库无法写入")
    end
  end)
end
function M.fini(env)
  if env.her_memory_connection then env.her_memory_connection:disconnect(); env.her_memory_connection = nil end
end
return M
