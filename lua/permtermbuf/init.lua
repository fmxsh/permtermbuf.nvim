local M = {}

-- Store terminal buffers and windows for each program.
local terminals = {}

-- Store the original values to restore later
local original_settings = {
	laststatus = vim.o.laststatus,
	showtabline = vim.o.showtabline,
	cmdheight = vim.o.cmdheight,
	signcolumn = vim.wo.signcolumn,
	number = vim.wo.number,
	relativenumber = vim.wo.relativenumber,
}

-- Function to hide the status line, tabline, command line, sign column, and line number column
function M.hide_ui_elements()
	vim.o.laststatus = 0
	vim.o.showtabline = 0
	vim.o.cmdheight = 0
	vim.wo.signcolumn = "no" -- Hide sign column
	vim.wo.relativenumber = false -- Turn off relative line numbers first
	vim.wo.number = false -- Then turn off absolute line numbers
end

-- Function to restore the original values
function M.restore_ui_elements()
	vim.wo.number = original_settings.number -- Restore absolute line numbers first
	vim.wo.relativenumber = original_settings.relativenumber -- Then restore relative line numbers
	vim.wo.signcolumn = original_settings.signcolumn
	vim.o.laststatus = original_settings.laststatus
	vim.o.showtabline = original_settings.showtabline
	vim.o.cmdheight = original_settings.cmdheight
end

M.is_active = false -- if we have a terminal open or not
-- Utility function to check if a buffer with a given name exists
local function get_buf_by_name(name)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf):match(name) then
			return buf
		end
	end
	return nil
end

-- Function to save the current window layout
local function save_layout(program)
	terminals[program].previous_layout = vim.fn.winrestcmd()
end

-- Function to restore the previous window layout
local function restore_layout(program)
	if terminals[program].previous_layout then
		vim.cmd(terminals[program].previous_layout)
	end
end

-- Callback function to handle terminal output
local function handle_output(program)
	local buf = terminals[program].buf
	-- Only process output if the program exited, not if it was manually closed
	if terminals[program].exited then
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		-- Process lines and call the callback defined for the program
		if terminals[program].callback_on_exit then
			-- Return whatever text the cakkback wants to show as confirmation
			return terminals[program].callback_on_exit(lines)
		end
		return "Program didn't exit normally: " .. program
	end
	return "No callback defined for " .. program
end

-- Function to close terminal and handle cleanup
local function close_terminal(program, program_exited)
	local term = terminals[program]
	if term.win and vim.api.nvim_win_is_valid(term.win) then
		vim.api.nvim_win_close(term.win, true)
		term.win = nil
		restore_layout(program)

		-- Set a flag if the terminal is closed due to the program exiting
		term.exited = program_exited or false

		-- Only trigger callback if the program exited (not when toggled out)
		if program_exited then
			local ret = handle_output(program)
			-- if ret not nil
			if ret then
				-- TODO: Syoulnt there be a return here?
				--log("Program exited: " .. ret .. "")
				-- print("Program exited: " .. ret)
			end
		end

		-- Only delete the buffer if the program has exited
		if term.exited and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
			vim.cmd("silent! bwipeout! " .. term.buf) -- Silent buffer deletion
			--vim.cmd("silent! bdelete! " .. term.buf) -- Silent buffer deletion
			term.buf = nil
		end

		vim.api.nvim_exec_autocmds("User", { pattern = "PermTermBufExit" })
	end
end

-- Function to close any other program tabs except the current one
local function close_other_program_tabs(current_program_name)
	for program_name, term in pairs(terminals) do
		-- Skip the current program
		if program_name ~= current_program_name then
			-- Close the terminal window if it's open
			if term.win and vim.api.nvim_win_is_valid(term.win) then
				close_terminal(program_name, false)
			end
		end
	end
end

-- Generic function to toggle a terminal for any program
local function toggle_terminal(program)
	local term = terminals[program]
	local term_buf = get_buf_by_name(term.buffer_name)

	-- If the terminal is already open, close it and cleanup
	if term.win and vim.api.nvim_win_is_valid(term.win) then
		-- Close terminal manually, indicating the program didn't exit naturally
		close_terminal(program, false)
		M.is_active = false
		M.restore_ui_elements()
		--log("Close the permterm")
		--vim.api.nvim_exec_autocmds("User", { pattern = "PermTermBufExit" })
	else
		-- Not open, so open it

		-- Save the layout before opening a terminal
		save_layout(program)
		M.is_active = true
		-- NOTE: We do not start the program several times, only once then toggle showing the buffer
		-- So having both first_toggle_cmd and cmd is redundant,
		-- Remove it, or add logic to actually check if it is the first toggle or not
		-- Program can exit for other reasons and that buffer cleared and we retoggle whereas it is not first toggle
		-- TODO: Fix that... It has been fixed
		-- If buffer exists, reuse it
		if term_buf then
			M.hide_ui_elements()
			vim.cmd("tabnew") -- Open a new tab (simulate full screen)
			vim.api.nvim_set_current_buf(term_buf)
			term.win = vim.api.nvim_get_current_win()
			vim.cmd("startinsert")
		else
			-- Create new terminal buffer if it doesn't exist
			--
			-- This is the first toggle, so we apply initial logic
			-- If no first_toggle_cmd, check if cmd_callback exists and modify term.cmd
			local cmd = term.cmd
			if term.callback_pre_exec_cmd and type(term.callback_pre_exec_cmd) == "function" then
				cmd = term.callback_pre_exec_cmd(cmd) -- Modify cmd with callback
			end

			if cmd == nil then
				log("No command to run, nil returned")
				return
			end
			--now when we know we want to continue, we can hide the ui elements
			M.hide_ui_elements()
			term_buf = vim.api.nvim_create_buf(false, true)
			vim.cmd("tabnew")
			local tab_id = vim.api.nvim_get_current_tabpage()
			vim.api.nvim_set_current_buf(term_buf)
			vim.cmd("terminal " .. cmd)
			--log("terminal " .. cmd)
			if term.callback_post_exec_cmd and type(term.callback_post_exec_cmd) == "function" then
				term.callback_post_exec_cmd()
			end

			-- Set buffer name and save window reference
			vim.api.nvim_buf_set_name(term_buf, term.buffer_name)

			-- Mark the buffer as unlisted using nvim_set_option_value
			vim.api.nvim_set_option_value("buflisted", false, { buf = term_buf })

			term.win = vim.api.nvim_get_current_win()
			term.tab_id = tab_id

			-- Store buffer and window
			term.buf = term_buf

			-- Enter insert mode
			vim.cmd("startinsert")

			-- Attach autocmd to handle terminal exit
			vim.api.nvim_create_autocmd("TermClose", {
				buffer = term_buf,
				callback = function()
					-- Close terminal indicating the program exited
					close_terminal(program, true)

					M.restore_ui_elements()
				end,
			})
		end

		M.is_active = true
	end
end

-- Function to check if the current buffer is a terminal buffer
function M.current_is_terminal_buffer()
	local current_buf = vim.api.nvim_get_current_buf()
	for _, term in pairs(terminals) do
		if term.buf == current_buf then
			return true
		end
	end
	return false
end

-- Setup function to initialize the plugin with a list of programs
function M.setup(programs)
	-- Modify sessionoptions to remove 'terminal'
	local sessionoptions = vim.opt.sessionoptions:get() -- Get the current sessionoptions
	if vim.tbl_contains(sessionoptions, "terminal") then
		vim.opt.sessionoptions:remove("terminal") -- Remove 'terminal' from sessionoptions
	end
	-- Debug: Check the passed programs table
	--print("Programs table:", vim.inspect(programs))
	for _, program in pairs(programs) do
		-- Initialize program state
		terminals[program.name] = {
			cmd = program.cmd,
			buffer_name = program.buffer_name,
			win = nil,
			buf = nil,
			previous_layout = nil,
			callback_on_exit = program.callback_on_exit, -- Store callback for each program
			callback_pre_exec_cmd = program.callback_pre_exec_cmd, -- Store callback for each program
			callback_post_exec_cmd = program.callback_post_exec_cmd, -- Store callback for each program
			exited = false, -- Flag to track if program exited
		}

		-- Create a toggle function for each program
		M[program.name] = {}
		M[program.name].toggle = function()
			toggle_terminal(program.name)
		end

		-- Add this for debugging
		--print("Assigned post exec cmd for", program.name, vim.inspect(terminals[program.name].callback_post_exec_cmd))
	end
	--	require("nvim-signtext").print("initiated permtermbuf")
end

return M
