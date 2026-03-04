local lsp = require('amazonq.lsp')
local log = require('amazonq.log')

local M = {}
local ns = vim.api.nvim_create_namespace('amazonq_inline')
local current = nil -- { bufnr, row, col, text }
local debounce_timer = nil
local enabled = false
local skip_next_trigger = false
local debounce_ms = 300
local request_seq = 0 -- monotonic counter to discard stale responses

--- Get the main amazonq LSP client for the current buffer.
function M.get_client()
  local clients = vim.lsp.get_clients({ bufnr = 0, name = 'amazonq' })
  return clients[1]
end

--- Returns true if a ghost text suggestion is currently visible.
function M.has_suggestion()
  return current ~= nil
end

--- Clear displayed ghost text.
function M.clear()
  if current then
    pcall(vim.api.nvim_buf_clear_namespace, current.bufnr, ns, 0, -1)
  end
  pcall(vim.api.nvim_buf_clear_namespace, 0, ns, 0, -1)
  current = nil
end

--- Render suggestion as ghost text at the given position.
local function show(bufnr, text, row, col)
  M.clear()
  local lines = vim.split(text, '\n', { plain = true })
  if #lines == 0 or (#lines == 1 and lines[1] == '') then
    return
  end

  local virt_lines = {}
  for i = 2, #lines do
    table.insert(virt_lines, { { lines[i], 'AmazonQInlineSuggestion' } })
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
    virt_text = { { lines[1], 'AmazonQInlineSuggestion' } },
    virt_text_pos = 'inline',
    virt_lines = #virt_lines > 0 and virt_lines or nil,
  })
  current = { bufnr = bufnr, row = row, col = col, text = text }
end

--- Request inline completion from the LSP and display as ghost text.
function M.trigger()
  local client = M.get_client()
  if not client then
    return
  end

  request_seq = request_seq + 1
  local seq = request_seq

  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { triggerKind = 1 }

  lsp.lsp_request(client, 'aws/textDocument/inlineCompletionWithReferences', params, function(err, result)
    if err then
      log.log(('Inline completion error: %s'):format(vim.inspect(err)), vim.log.levels.DEBUG)
      return
    end
    if not result or not result.items or #result.items == 0 then
      return
    end
    vim.schedule(function()
      -- Discard if a newer request was made since this one.
      if seq ~= request_seq then
        return
      end
      if vim.fn.mode() ~= 'i' then
        return
      end
      local text = result.items[1].insertText
      if not text or vim.trim(text) == '' then
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      show(bufnr, text, cursor[1] - 1, cursor[2])
    end)
  end)
end

--- Accept a partial chunk of the suggestion, keep the rest as ghost text.
local function do_accept_partial(chunk)
  local s = current
  M.clear()

  local remaining = s.text:sub(#chunk + 1)
  local cur_line = vim.api.nvim_buf_get_lines(s.bufnr, s.row, s.row + 1, false)[1] or ''
  local before = cur_line:sub(1, s.col)
  local after = cur_line:sub(s.col + 1)

  local chunk_lines = vim.split(chunk, '\n', { plain = true })
  chunk_lines[1] = before .. chunk_lines[1]
  chunk_lines[#chunk_lines] = chunk_lines[#chunk_lines] .. after

  vim.api.nvim_buf_set_lines(s.bufnr, s.row, s.row + 1, false, chunk_lines)
  local end_row = s.row + #chunk_lines - 1
  local end_col = #chunk_lines[#chunk_lines] - #after
  vim.api.nvim_win_set_cursor(0, { end_row + 1, end_col })

  if remaining ~= '' then
    skip_next_trigger = true
    show(s.bufnr, remaining, end_row, end_col)
  end
end

local function do_accept()
  if current then
    do_accept_partial(current.text)
  end
end

local function do_accept_word()
  if current then
    do_accept_partial(current.text:match('^(%S+%s*)') or current.text)
  end
end

local function do_accept_line()
  if current then
    do_accept_partial(current.text:match('^([^\n]*\n?)') or current.text)
  end
end

local function termcodes(key)
  return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function feedkeys(key)
  vim.api.nvim_feedkeys(termcodes(key), 'n', true)
end

--- Accept full suggestion, or send fallback key.
--- @param fallback? string
function M.accept(fallback)
  if current then
    do_accept()
  elseif fallback then
    feedkeys(fallback)
  end
end

--- Accept next word, or send fallback key.
--- @param fallback? string
function M.accept_word(fallback)
  if current then
    do_accept_word()
  elseif fallback then
    feedkeys(fallback)
  end
end

--- Accept next line, or send fallback key.
--- @param fallback? string
function M.accept_line(fallback)
  if current then
    do_accept_line()
  elseif fallback then
    feedkeys(fallback)
  end
end

--- Dismiss suggestion, or send fallback key.
--- @param fallback? string
function M.dismiss(fallback)
  if current then
    M.clear()
  elseif fallback then
    feedkeys(fallback)
  end
end

--- Schedule a debounced trigger.
local function schedule_trigger()
  if skip_next_trigger then
    skip_next_trigger = false
    return
  end
  M.clear()
  -- Bump seq so any in-flight response is discarded.
  request_seq = request_seq + 1
  if debounce_timer then
    debounce_timer:stop()
  end
  debounce_timer = vim.defer_fn(M.trigger, debounce_ms)
end

function M.setup(opts)
  opts = opts or {}
  debounce_ms = opts.debounce_ms or 300
  vim.api.nvim_set_hl(0, 'AmazonQInlineSuggestion', { default = true, link = 'Comment' })
end

--- Enable inline suggestions for the given buffer.
function M.start()
  if enabled then
    return
  end
  enabled = true

  vim.api.nvim_create_autocmd({ 'TextChangedI' }, {
    group = lsp.augroup,
    callback = schedule_trigger,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group = lsp.augroup,
    callback = M.clear,
  })
end

return M
