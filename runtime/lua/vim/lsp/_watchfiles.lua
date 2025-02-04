local bit = require('bit')
local watch = require('vim._watch')
local protocol = require('vim.lsp.protocol')
local ms = protocol.Methods
local lpeg = vim.lpeg

local M = {}

--- Parses the raw pattern into an |lpeg| pattern. LPeg patterns natively support the "this" or "that"
--- alternative constructions described in the LSP spec that cannot be expressed in a standard Lua pattern.
---
---@param pattern string The raw glob pattern
---@return vim.lpeg.Pattern? pattern An |lpeg| representation of the pattern, or nil if the pattern is invalid.
local function parse(pattern)
  local l = lpeg

  local P, S, V = lpeg.P, lpeg.S, lpeg.V
  local C, Cc, Ct, Cf = lpeg.C, lpeg.Cc, lpeg.Ct, lpeg.Cf

  local pathsep = '/'

  local function class(inv, ranges)
    for i, r in ipairs(ranges) do
      ranges[i] = r[1] .. r[2]
    end
    local patt = l.R(unpack(ranges))
    if inv == '!' then
      patt = P(1) - patt
    end
    return patt
  end

  local function add(acc, a)
    return acc + a
  end

  local function mul(acc, m)
    return acc * m
  end

  local function star(stars, after)
    return (-after * (l.P(1) - pathsep)) ^ #stars * after
  end

  local function dstar(after)
    return (-after * l.P(1)) ^ 0 * after
  end

  local p = P({
    'Pattern',
    Pattern = V('Elem') ^ -1 * V('End'),
    Elem = Cf(
      (V('DStar') + V('Star') + V('Ques') + V('Class') + V('CondList') + V('Literal'))
        * (V('Elem') + V('End')),
      mul
    ),
    DStar = P('**') * (P(pathsep) * (V('Elem') + V('End')) + V('End')) / dstar,
    Star = C(P('*') ^ 1) * (V('Elem') + V('End')) / star,
    Ques = P('?') * Cc(l.P(1) - pathsep),
    Class = P('[') * C(P('!') ^ -1) * Ct(Ct(C(1) * '-' * C(P(1) - ']')) ^ 1 * ']') / class,
    CondList = P('{') * Cf(V('Cond') * (P(',') * V('Cond')) ^ 0, add) * '}',
    -- TODO: '*' inside a {} condition is interpreted literally but should probably have the same
    -- wildcard semantics it usually has.
    -- Fixing this is non-trivial because '*' should match non-greedily up to "the rest of the
    -- pattern" which in all other cases is the entire succeeding part of the pattern, but at the end of a {}
    -- condition means "everything after the {}" where several other options separated by ',' may
    -- exist in between that should not be matched by '*'.
    Cond = Cf((V('Ques') + V('Class') + V('CondList') + (V('Literal') - S(',}'))) ^ 1, mul)
      + Cc(l.P(0)),
    Literal = P(1) / l.P,
    End = P(-1) * Cc(l.P(-1)),
  })

  return p:match(pattern) --[[@as vim.lpeg.Pattern?]]
end

---@private
--- Implementation of LSP 3.17.0's pattern matching: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#pattern
---
---@param pattern string|vim.lpeg.Pattern The glob pattern (raw or parsed) to match.
---@param s string The string to match against pattern.
---@return boolean Whether or not pattern matches s.
function M._match(pattern, s)
  if type(pattern) == 'string' then
    local p = assert(parse(pattern))
    return p:match(s) ~= nil
  end
  return pattern:match(s) ~= nil
end

M._watchfunc = (vim.fn.has('win32') == 1 or vim.fn.has('mac') == 1) and watch.watch or watch.poll

---@type table<integer, table<string, function[]>> client id -> registration id -> cancel function
local cancels = vim.defaulttable()

local queue_timeout_ms = 100
---@type table<integer, uv.uv_timer_t> client id -> libuv timer which will send queued changes at its timeout
local queue_timers = {}
---@type table<integer, lsp.FileEvent[]> client id -> set of queued changes to send in a single LSP notification
local change_queues = {}
---@type table<integer, table<string, lsp.FileChangeType>> client id -> URI -> last type of change processed
--- Used to prune consecutive events of the same type for the same file
local change_cache = vim.defaulttable()

---@type table<vim._watch.FileChangeType, lsp.FileChangeType>
local to_lsp_change_type = {
  [watch.FileChangeType.Created] = protocol.FileChangeType.Created,
  [watch.FileChangeType.Changed] = protocol.FileChangeType.Changed,
  [watch.FileChangeType.Deleted] = protocol.FileChangeType.Deleted,
}

--- Default excludes the same as VSCode's `files.watcherExclude` setting.
--- https://github.com/microsoft/vscode/blob/eef30e7165e19b33daa1e15e92fa34ff4a5df0d3/src/vs/workbench/contrib/files/browser/files.contribution.ts#L261
---@type vim.lpeg.Pattern parsed Lpeg pattern
M._poll_exclude_pattern = parse('**/.git/{objects,subtree-cache}/**')
  + parse('**/node_modules/*/**')
  + parse('**/.hg/store/**')

--- Registers the workspace/didChangeWatchedFiles capability dynamically.
---
---@param reg lsp.Registration LSP Registration object.
---@param ctx lsp.HandlerContext Context from the |lsp-handler|.
function M.register(reg, ctx)
  local client_id = ctx.client_id
  local client = assert(vim.lsp.get_client_by_id(client_id), 'Client must be running')
  -- Ill-behaved servers may not honor the client capability and try to register
  -- anyway, so ignore requests when the user has opted out of the feature.
  local has_capability = vim.tbl_get(
    client.config.capabilities or {},
    'workspace',
    'didChangeWatchedFiles',
    'dynamicRegistration'
  )
  if not has_capability or not client.workspace_folders then
    return
  end
  local register_options = reg.registerOptions --[[@as lsp.DidChangeWatchedFilesRegistrationOptions]]
  ---@type table<string, {pattern: vim.lpeg.Pattern, kind: lsp.WatchKind}[]> by base_dir
  local watch_regs = vim.defaulttable()
  for _, w in ipairs(register_options.watchers) do
    local kind = w.kind
      or (protocol.WatchKind.Create + protocol.WatchKind.Change + protocol.WatchKind.Delete)
    local glob_pattern = w.globPattern

    if type(glob_pattern) == 'string' then
      local pattern = parse(glob_pattern)
      if not pattern then
        error('Cannot parse pattern: ' .. glob_pattern)
      end
      for _, folder in ipairs(client.workspace_folders) do
        local base_dir = vim.uri_to_fname(folder.uri)
        table.insert(watch_regs[base_dir], { pattern = pattern, kind = kind })
      end
    else
      local base_uri = glob_pattern.baseUri
      local uri = type(base_uri) == 'string' and base_uri or base_uri.uri
      local base_dir = vim.uri_to_fname(uri)
      local pattern = parse(glob_pattern.pattern)
      if not pattern then
        error('Cannot parse pattern: ' .. glob_pattern.pattern)
      end
      pattern = lpeg.P(base_dir .. '/') * pattern
      table.insert(watch_regs[base_dir], { pattern = pattern, kind = kind })
    end
  end

  ---@param base_dir string
  local callback = function(base_dir)
    return function(fullpath, change_type)
      local registrations = watch_regs[base_dir]
      for _, w in ipairs(registrations) do
        local lsp_change_type = assert(
          to_lsp_change_type[change_type],
          'Must receive change type Created, Changed or Deleted'
        )
        -- e.g. match kind with Delete bit (0b0100) to Delete change_type (3)
        local kind_mask = bit.lshift(1, lsp_change_type - 1)
        local change_type_match = bit.band(w.kind, kind_mask) == kind_mask
        if w.pattern:match(fullpath) ~= nil and change_type_match then
          ---@type lsp.FileEvent
          local change = {
            uri = vim.uri_from_fname(fullpath),
            type = lsp_change_type,
          }

          local last_type = change_cache[client_id][change.uri]
          if last_type ~= change.type then
            change_queues[client_id] = change_queues[client_id] or {}
            table.insert(change_queues[client_id], change)
            change_cache[client_id][change.uri] = change.type
          end

          if not queue_timers[client_id] then
            queue_timers[client_id] = vim.defer_fn(function()
              ---@type lsp.DidChangeWatchedFilesParams
              local params = {
                changes = change_queues[client_id],
              }
              client.notify(ms.workspace_didChangeWatchedFiles, params)
              queue_timers[client_id] = nil
              change_queues[client_id] = nil
              change_cache[client_id] = nil
            end, queue_timeout_ms)
          end

          break -- if an event matches multiple watchers, only send one notification
        end
      end
    end
  end

  for base_dir, watches in pairs(watch_regs) do
    local include_pattern = vim.iter(watches):fold(lpeg.P(false), function(acc, w)
      return acc + w.pattern
    end)

    table.insert(
      cancels[client_id][reg.id],
      M._watchfunc(base_dir, {
        uvflags = {
          recursive = true,
        },
        -- include_pattern will ensure the pattern from *any* watcher definition for the
        -- base_dir matches. This first pass prevents polling for changes to files that
        -- will never be sent to the LSP server. A second pass in the callback is still necessary to
        -- match a *particular* pattern+kind pair.
        include_pattern = include_pattern,
        exclude_pattern = M._poll_exclude_pattern,
      }, callback(base_dir))
    )
  end
end

--- Unregisters the workspace/didChangeWatchedFiles capability dynamically.
---
---@param unreg lsp.Unregistration LSP Unregistration object.
---@param ctx lsp.HandlerContext Context from the |lsp-handler|.
function M.unregister(unreg, ctx)
  local client_id = ctx.client_id
  local client_cancels = cancels[client_id]
  local reg_cancels = client_cancels[unreg.id]
  while #reg_cancels > 0 do
    table.remove(reg_cancels)()
  end
  client_cancels[unreg.id] = nil
  if not next(cancels[client_id]) then
    cancels[client_id] = nil
  end
end

return M
