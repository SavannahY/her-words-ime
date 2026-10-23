-- Independent Spanish word composition; no host text, clipboard or network.
local core = require("her_latin_core")
local REJECTED, ACCEPTED, NOOP = 0, 1, 2
local BACKSPACE, TAB, RETURN, ESCAPE = 0xff08, 0xff09, 0xff0d, 0xff1b
local LEFT, UP, RIGHT, DOWN = 0xff51, 0xff52, 0xff53, 0xff54
local HOME, END, DELETE = 0xff50, 0xff57, 0xffff

local function commit(context, engine)
  if context:is_composing() then
    -- A suppressed spelling has no candidate. Do not bypass its block policy
    -- by asking the context to fall back to its raw input.
    if context:get_selected_candidate() then context:commit() else context:clear() end
  end
end

local function process(key, env)
  local context = env.engine.context
  if key:release() then return NOOP end
  local code = key.keycode
  if key:ctrl() or key:alt() or key:super() then
    commit(context, env.engine)
    return REJECTED
  end
  if code == ESCAPE then
    if context:is_composing() then context:clear(); return ACCEPTED end
    return REJECTED
  end
  if code == BACKSPACE and context:is_composing() then
    local raw, caret = context.input, context.caret_pos
    if caret > 0 then
      local begin_at = utf8.offset(raw:sub(1, caret), -1)
      if begin_at then context:pop_input(caret - begin_at + 1) end
    end
    env.her_latin_prefix = false
    return ACCEPTED
  end
  if code == DELETE and context:is_composing() then
    local raw, caret = context.input, context.caret_pos
    if caret < #raw then
      local next_at = utf8.offset(raw, 2, caret + 1) or (#raw + 1)
      context:delete_input(next_at - caret - 1)
    end
    return ACCEPTED
  end
  if code == TAB and context:is_composing() then
    if not context:has_menu() then return ACCEPTED end
    local segment = context.composition:back()
    local index = segment.selected_index + (key:shift() and -1 or 1)
    if index < 0 or not context:highlight(index) then context:highlight(0) end
    return ACCEPTED
  end
  if code == UP or code == DOWN then
    if context:is_composing() and context:has_menu() then return NOOP end
    commit(context, env.engine)
    return REJECTED
  end
  if code == LEFT or code == RIGHT or code == HOME or code == END then
    commit(context, env.engine)
    return REJECTED
  end
  if code == RETURN then
    commit(context, env.engine)
    return REJECTED
  end
  if code == 32 then
    if context:is_composing() then
      commit(context, env.engine)
      env.engine:commit_text(" ")
      return ACCEPTED
    end
    return REJECTED
  end
  local text = core.printable(code)
  if not text then return NOOP end
  local raw = context.input
  -- Store actual accented text in the context, not an encoded preedit. Squirrel
  -- can flush context.input directly when focus moves to a different app.
  local accent = env.her_latin_prefix and raw:sub(-1) == ";" and core.accent(text)
  env.her_latin_prefix = false
  if accent then
    context:pop_input(1)
    context:push_input(accent)
    if text == "?" or text == "!" then commit(context, env.engine) end
    return ACCEPTED
  end
  if core.is_letter(text) or text == ";" then
    if #raw >= 128 then commit(context, env.engine) end
    context:push_input(text)
    env.her_latin_prefix = text == ";"
    return ACCEPTED
  end
  if (text == "'" or text == "-") and context:is_composing() then
    context:push_input(text)
    return ACCEPTED
  end
  commit(context, env.engine)
  return REJECTED
end

return { func = process }
