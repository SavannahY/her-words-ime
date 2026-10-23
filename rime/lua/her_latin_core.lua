-- Small, offline Spanish helpers. Explicit accents never alter unmarked text.
local M = {}
local accents = {
  a = "á", e = "é", i = "í", o = "ó", u = "ú", n = "ñ", v = "ü",
  A = "Á", E = "É", I = "Í", O = "Ó", U = "Ú", N = "Ñ", V = "Ü",
  ["?"] = "¿", ["!"] = "¡", [";"] = ";",
}
local lower = { ["Á"] = "á", ["É"] = "é", ["Í"] = "í", ["Ó"] = "ó",
  ["Ú"] = "ú", ["Ü"] = "ü", ["Ñ"] = "ñ" }
local plain = { ["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o",
  ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n" }

function M.expand(input)
  return (input:gsub(";([aAeEiIoOuUnNvV?!;])", accents))
end

function M.accent(char)
  return accents[char]
end

function M.lower(input)
  -- string.lower follows the host C locale and can corrupt individual UTF-8
  -- bytes in Squirrel. Fold ASCII explicitly, then complete Spanish scalars.
  return (input:gsub("[A-Z]", function(char) return string.char(char:byte() + 32) end)
      :gsub("[\194-\244][\128-\191]+", lower))
end

function M.code(input)
  return (M.lower(input):gsub("[\194-\244][\128-\191]+", plain):gsub("[^a-z]", ""))
end

function M.same_word(left, right)
  -- Terminal punctuation does not prevent an ordinary word showing its gloss.
  local function normalized(text)
    return M.lower(text):gsub("^[¿¡]+", ""):gsub("[.!?]+$", "")
  end
  return normalized(left) == normalized(right)
end

function M.comment(word, hints)
  if not hints then return "" end
  local result = word.meaning or ""
  if word.hint and word.hint ~= "" then result = result .. " · " .. word.hint end
  return result
end

function M.printable(keycode)
  if keycode >= 32 and keycode <= 126 then return string.char(keycode) end
  -- X11 uses Latin-1 directly, and 0x01000000 + scalar for other Unicode keys.
  if keycode >= 0x01000100 and keycode <= 0x0110ffff then
    return utf8.char(keycode - 0x01000000)
  end
  if keycode >= 160 and keycode <= 255 then return utf8.char(keycode) end
end

function M.is_letter(text)
  return text:match("^[a-zA-Z0-9]$") ~= nil or plain[M.lower(text)] ~= nil
end

return M
