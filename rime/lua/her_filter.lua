-- 她说：女性优先与友好表达过滤器。
-- Loaded by lua_filter@*her_filter after simplifier, before uniquifier.
-- Rule data lives separately so wording changes do not require engine changes.
local rule_data = require("her_rewrite_rules")
local memory = require("her_memory")
local rules = {}

for index, rule in ipairs(rule_data.rules or {}) do
  if type(rule.from) == "string" and rule.from ~= ""
      and type(rule.to) == "string" then
    rules[#rules + 1] = {
      from = rule.from,
      to = rule.to,
      to_traditional = rule.to_traditional,
      community = rule.community,
      community_traditional = rule.community_traditional,
      exact = rule.match == "exact",
      order = index,
    }
  end
end

-- A longer literal wins when two rules begin at the same source position.
table.sort(rules, function(left, right)
  if #left.from == #right.from then
    return left.order < right.order
  end
  return #left.from > #right.from
end)

local function feminine(text)
  -- Neither literal contains Lua pattern/replacement metacharacters.
  return (text:gsub("他", "她"))
end

local function preferred(rule, community, simplified)
  if community then
    if not simplified and type(rule.community_traditional) == "string" then
      return rule.community_traditional
    end
    if type(rule.community) == "string" then
      return rule.community
    end
  end
  if not simplified and type(rule.to_traditional) == "string" then
    return rule.to_traditional
  end
  return rule.to
end

local function rewrite(text, enabled, community, simplified)
  if not enabled then
    return feminine(text), false
  end

  local parts = {}
  local position = 1
  local changed = false
  while position <= #text do
    local first, last, selected
    for _, rule in ipairs(rules) do
      if not rule.exact or text == rule.from then
        -- The final true makes matching literal, including %, [, +, etc.
        local begin_at, end_at = text:find(rule.from, position, true)
        if begin_at and (not first or begin_at < first) then
          first, last, selected = begin_at, end_at, rule
        end
      end
    end
    if not selected then
      parts[#parts + 1] = text:sub(position)
      break
    end
    parts[#parts + 1] = text:sub(position, first - 1)
    local replacement = preferred(selected, community, simplified)
    parts[#parts + 1] = replacement
    changed = changed or replacement ~= text:sub(first, last)
    position = last + 1
  end
  -- Replacements are never passed through the rules again. The independent
  -- pronoun preference applies to every output, including rule replacements.
  return feminine(table.concat(parts)), changed
end

local function annotation(comment, label)
  if comment == "" then
    return label
  end
  return comment .. " · " .. label
end

local function filter(input, env)
  memory.refresh(env)
  local context = env.engine.context
  local community = context:get_option("her_community")
  local enabled = context:get_option("her_friendly") or community
  local simplified = context:get_option("zh_hans") or context:get_option("zh_simp")
  local label = community and "社群写法" or "友好表达"
  local seen = {}
  local pending_aliases

  local function emit(candidate, text, comment)
    if memory.is_blocked(env, candidate.text) or memory.is_blocked(env, text)
        or memory.is_blocked(env, comment) then return end
    local key = tostring(candidate.start) .. ":"
        .. tostring(candidate._end) .. ":" .. text
    if seen[key] then
      return
    end
    seen[key] = true
    if text ~= candidate.text or comment ~= (candidate.comment or "") then
      -- Keep the Phrase/Sentence and its learning metadata via ShadowCandidate.
      -- Wrapping the current candidate also preserves simplifier conversion.
      yield(ShadowCandidate(candidate, candidate.type, text, comment))
    else
      yield(candidate)
    end
  end

  local composition = context.composition
  if not context:get_option("ascii_mode") and not composition:empty() then
    local segment = composition:back()
    if segment and segment:has_tag("abc") then
      local raw = context.input:sub(segment.start + 1, segment._end)
      raw = raw:gsub("[%s']", "")
      local priority
      if raw == "ta" then
        priority = "她"
      elseif raw == "tamen" then
        priority = simplified and "她们" or "她們"
      end
      if priority then
        -- A new Candidate avoids learning a genuine candidate such as 塔.
        local candidate = Candidate("her_priority", segment.start,
            segment._end, priority, "")
        emit(candidate, priority, "")
      end

      for _, word in ipairs(memory.suggestions(env, raw)) do
        local text, replaced = rewrite(word.text, enabled, community, simplified)
        local comment = word.manual and "本地词库" or "本地记忆"
        if replaced then comment = annotation(comment, label) end
        emit(Candidate("her_memory", segment.start, segment._end, word.text, ""), text, comment)
      end

      if enabled then
        pending_aliases = { raw = raw, start = segment.start, finish = segment._end }
      end
    end
  end

  local function emit_aliases()
    if not pending_aliases then
      return
    end
    local segment = pending_aliases
    pending_aliases = nil
    for _, alias in ipairs(rule_data.exact_aliases or {}) do
      if segment.raw == alias.input and type(alias.friendly) == "string" then
        local text = alias.friendly
        if not simplified and type(alias.friendly_traditional) == "string" then
          text = alias.friendly_traditional
        end
        if community then
          if not simplified and type(alias.community_traditional) == "string" then
            text = alias.community_traditional
          elseif type(alias.community) == "string" then
            text = alias.community
          end
        end
        text = feminine(text)
        local note = community and alias.community_note or alias.friendly_note
        local comment = label
        if type(note) == "string" and note ~= "" then
          comment = annotation(comment, note)
        end
        local candidate = Candidate("her_friendly_alias", segment.start,
            segment.finish, text, comment)
        emit(candidate, text, comment)
      end
    end
  end

  -- Consume only as downstream consumers request candidates. Do not collect or
  -- exhaust the translation: sentence ranking and candidate paging stay lazy.
  -- A benign homophone such as 坚韧 keeps its original first place. When the
  -- candidate actually needed a rewrite, a whole-input alias takes priority:
  -- this avoids splicing 新机 + 婊子 into 新机言行失当的人 for xinjibiaozi.
  for candidate in input:iter() do
    local text, replaced = rewrite(candidate.text, enabled, community, simplified)
    local comment = feminine(candidate.comment or "")
    if replaced then
      comment = annotation(comment, label)
    end
    if replaced then emit_aliases() end
    emit(candidate, text, comment)
    emit_aliases()
  end
  -- A translator with no candidates can still provide a friendly alias.
  emit_aliases()
end

return { init = memory.init, fini = memory.fini, func = filter }
