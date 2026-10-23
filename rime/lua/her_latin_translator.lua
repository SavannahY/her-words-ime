local core = require("her_latin_core")
local data = require("her_spanish_data")
local memory = require("her_memory")

local function init(env)
  -- Shared suppression policy applies here; selecting a phrase must not teach
  -- Chinese pinyin memory an unrelated Latin spelling.
  env.her_memory_readonly = true
  memory.init(env)
end

local function translate(input, segment, env)
  memory.refresh(env)
  local text = input
  local hints = env.engine.context:get_option("her_es_hints")
  local raw_comment = ""
  for _, word in ipairs(data.entries) do
    if core.same_word(text, word.text) then
      raw_comment = core.comment(word, hints)
      break
    end
  end
  local seen = {}
  local function emit(value, comment)
    if seen[value] or memory.is_blocked(env, value)
        or memory.is_blocked(env, comment) then return end
    seen[value] = true
    local candidate = Candidate("her_spanish", segment.start, segment._end, value, comment)
    candidate.preedit = text
    yield(candidate)
  end
  -- Never promote an accented/expanded phrase to first place just because the
  -- raw spelling was suppressed. An annotation can instead be hidden alone.
  if memory.is_blocked(env, text) then return end
  if memory.is_blocked(env, raw_comment) then raw_comment = "" end
  emit(text, raw_comment)
  local code = core.code(text)
  if #code >= 2 then
    -- Exact code matches precede prefix phrase suggestions. Raw text stays first.
    for _, prefix in ipairs({ false, true }) do
      for _, word in ipairs(data.entries) do
        if word.input == code or (prefix and word.input:sub(1, #code) == code) then
          if prefix or word.input == code then emit(word.text, core.comment(word, hints)) end
        end
      end
    end
  end
end

return { init = init, fini = memory.fini, func = translate }
