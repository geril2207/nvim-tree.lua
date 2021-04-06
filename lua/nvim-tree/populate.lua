local config = require'nvim-tree.config'
local git = require'nvim-tree.git'
local icon_config = config.get_icon_state()

local api = vim.api
local luv = vim.loop

local M = {
  show_ignored = false,
  show_dotfiles = vim.g.nvim_tree_hide_dotfiles ~= 1,
}

local utils = require'nvim-tree.utils'
local path_to_matching_str = utils.path_to_matching_str

local function dir_new(cwd, name)

  local absolute_path = utils.path_join({cwd, name})
  local stat = luv.fs_stat(absolute_path)
  local handle = luv.fs_scandir(absolute_path)
  local has_children = handle and luv.fs_scandir_next(handle) ~= nil

  --- This is because i have some folders that i dont have permissions to read its metadata, so i have to check that stat returns a valid info
  local last_modified = 0
  if stat ~= nil then
    last_modified = stat.mtime.sec
  end

  return {
    name = name,
    absolute_path = absolute_path,
    -- TODO: last modified could also involve atime and ctime
    last_modified = last_modified,
    match_name = path_to_matching_str(name),
    match_path = path_to_matching_str(absolute_path),
    open = false,
    group_next = nil,   -- If node is grouped, this points to the next child dir/link node
    has_children = has_children,
    entries = {}
  }
end

local function file_new(cwd, name)
  local absolute_path = utils.path_join({cwd, name})
  local is_exec = luv.fs_access(absolute_path, 'X')
  return {
    name = name,
    absolute_path = absolute_path,
    executable = is_exec,
    extension = vim.fn.fnamemodify(name, ':e') or "",
    match_name = path_to_matching_str(name),
    match_path = path_to_matching_str(absolute_path),
  }
end

-- TODO-INFO: sometimes fs_realpath returns nil
-- I expect this be a bug in glibc, because it fails to retrieve the path for some
-- links (for instance libr2.so in /usr/lib) and thus even with a C program realpath fails
-- when it has no real reason to. Maybe there is a reason, but errno is definitely wrong.
-- So we need to check for link_to ~= nil when adding new links to the main tree
local function link_new(cwd, name)

  --- I dont know if this is needed, because in my understanding, there isnt hard links in windows, but just to be sure i changed it.
  local absolute_path = utils.path_join({ cwd, name })
  local link_to = luv.fs_realpath(absolute_path)
  local open, entries
  if (link_to ~= nil) and luv.fs_stat(link_to).type == 'directory' then
    open = false
    entries = {}
  end
  return {
    name = name,
    absolute_path = absolute_path,
    link_to = link_to,
    open = open,
    entries = entries,
    match_name = path_to_matching_str(name),
    match_path = path_to_matching_str(absolute_path),
  }
end

-- Returns true if there is either exactly 1 dir, or exactly 1 symlink dir. Otherwise, false.
-- @param cwd Absolute path to the parent directory
-- @param dirs List of dir names
-- @param files List of file names
-- @param links List of symlink names
local function should_group(cwd, dirs, files, links)
  if #dirs == 1 and #files == 0 and #links == 0 then
    return true
  end

  if #dirs == 0 and #files == 0 and #links == 1 then
    local absolute_path = utils.path_join({ cwd, links[1] })
    local link_to = luv.fs_realpath(absolute_path)
    return (link_to ~= nil) and luv.fs_stat(link_to).type == 'directory'
  end

  return false
end

local function gen_ignore_check()
  local ignore_list = {}

  local function add_toignore(content)
    for s in content:gmatch("[^\r\n]+") do
      -- Trim trailing / from directories.
      s = s:gsub("/+$", "")
      ignore_list[s] = true
    end
  end

  if (vim.g.nvim_tree_gitignore or 0) == 1 then
    add_toignore(git.get_gitexclude())
  end

  if vim.g.nvim_tree_ignore and #vim.g.nvim_tree_ignore > 0 then
    for _, entry in pairs(vim.g.nvim_tree_ignore) do
      ignore_list[entry] = true
    end
  end

  return function(path)
    local idx = path:match(".+()%.%w+$")
    local ignore_extension
    if idx then
        ignore_extension = ignore_list['*'..string.sub(path, idx)]
    end
    local ignore_path = not M.show_ignored and ignore_list[path] == true
    local ignore_dotfiles = not M.show_dotfiles and path:sub(1, 1) == '.'
    return ignore_extension or ignore_path or ignore_dotfiles
  end
end

local should_ignore = gen_ignore_check()

function M.refresh_entries(entries, cwd, parent_node)
  local handle = luv.fs_scandir(cwd)
  if type(handle) == 'string' then
    api.nvim_err_writeln(handle)
    return
  end

  local named_entries = {}
  local cached_entries = {}
  local entries_idx = {}
  for i, node in ipairs(entries) do
    cached_entries[i] = node.name
    entries_idx[node.name] = i
    named_entries[node.name] = node
  end

  local dirs = {}
  local links = {}
  local files = {}
  local new_entries = {}
  local num_new_entries = 0

  while true do
    local name, t = luv.fs_scandir_next(handle)
    if not name then break end
    num_new_entries = num_new_entries + 1

    if not should_ignore(name) then
      if t == 'directory' then
        table.insert(dirs, name)
        new_entries[name] = true
      elseif t == 'file' then
        table.insert(files, name)
        new_entries[name] = true
      elseif t == 'link' then
        table.insert(links, name)
        new_entries[name] = true
      end
    end
  end

  -- Handle grouped dirs
  local next_node = parent_node.group_next
  if next_node then
    next_node.open = parent_node.open
    if num_new_entries ~= 1 or not new_entries[next_node.name] then
      -- dir is no longer only containing a group dir, or group dir has been removed
      -- either way: sever the group link on current dir
      parent_node.group_next = nil
      named_entries[next_node.name] = next_node
    else
      M.refresh_entries(entries, next_node.absolute_path, next_node)
      return
    end
  end

  local idx = 1
  for _, name in ipairs(cached_entries) do
    if not new_entries[name] then
      table.remove(entries, idx)
    else
      idx = idx + 1
    end
  end

  local all = {
    { entries = dirs, fn = dir_new, check = function(_, abs) return luv.fs_access(abs, 'R') end },
    { entries = links, fn = link_new, check = function(name) return name ~= nil end },
    { entries = files, fn = file_new, check = function() return true end }
  }

  local prev = nil
  local change_prev
  for _, e in ipairs(all) do
    for _, name in ipairs(e.entries) do
      change_prev = true
      if not named_entries[name] then
        local n = e.fn(cwd, name)
        if e.check(n.link_to, n.absolute_path) then
          idx = 1
          if prev then
            idx = entries_idx[prev] + 1
          end
          table.insert(entries, idx, n)
          entries_idx[name] = idx
          cached_entries[idx] = name
        else
          change_prev = false
        end
      end
      if change_prev and not (next_node and next_node.name == name) then
        prev = name
      end
    end
  end

  if next_node then
    table.insert(entries, 1, next_node)
  end
end

function M.populate(entries, cwd, parent_node)
  local handle = luv.fs_scandir(cwd)
  if type(handle) == 'string' then
    api.nvim_err_writeln(handle)
    return
  end

  local dirs = {}
  local links = {}
  local files = {}

  while true do
    local name, t = luv.fs_scandir_next(handle)
    if not name then break end

    if not should_ignore(name) then
      if t == 'directory' then
        table.insert(dirs, name)
      elseif t == 'file' then
        table.insert(files, name)
      elseif t == 'link' then
        table.insert(links, name)
      end
    end
  end

  -- Create Nodes --

  -- Group empty dirs
  if parent_node and vim.g.nvim_tree_group_empty == 1 then
    if should_group(cwd, dirs, files, links) then
      local child_node
      if dirs[1] then child_node = dir_new(cwd, dirs[1]) end
      if links[1] then child_node = link_new(cwd, links[1]) end
      if luv.fs_access(child_node.absolute_path, 'R') then
          parent_node.group_next = child_node
          M.populate(entries, child_node.absolute_path, child_node)
          return
      end
    end
  end

  for _, dirname in ipairs(dirs) do
    local dir = dir_new(cwd, dirname)
    if luv.fs_access(dir.absolute_path, 'R') then
      table.insert(entries, dir)
    end
  end

  for _, linkname in ipairs(links) do
    local link = link_new(cwd, linkname)
    if link.link_to ~= nil then
      table.insert(entries, link)
    end
  end

  for _, filename in ipairs(files) do
    local file = file_new(cwd, filename)
    table.insert(entries, file)
  end

  if (not icon_config.show_git_icon) and vim.g.nvim_tree_git_hl ~= 1 then
    return
  end

  git.update_status(entries, cwd)
end

return M