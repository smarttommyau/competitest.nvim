local api = vim.api
local config = require("competitest.config")
local testcases = require("competitest.testcases")
local utils = require("competitest.utils")
local M = {}

---Start testcase editor to add a new testcase or to edit a testcase that already exists
---@param add_testcase boolean: if true a new testcases will be added, otherwise edit a testcase that already exists
---@param tcnum integer: testcase number
function M.edit_testcase(add_testcase, tcnum)
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr) -- reload buffer configuration since it may have been updated in the meantime
	local tctbl = testcases.get_testcases(bufnr)
	if add_testcase then
		tcnum = 0
		while tctbl[tcnum] do
			tcnum = tcnum + 1
		end
		tctbl[tcnum] = { input = "", output = "" }
	end

	local function start_editor(item) -- item.id is testcase number
		if not tctbl[item.id] then
			utils.notify("edit_testcase: testcase " .. tostring(item.id or tcnum) .. " doesn't exist!")
			return
		end
		tcnum = item.id

		local function save_data(tc)
			if config.get_config(bufnr).testcases_use_single_file then
				tctbl[tcnum] = tc
				testcases.write_testcases_on_single_file(bufnr, tctbl)
			else
				testcases.write_testcase_on_files(bufnr, tcnum, tc.input, tc.output)
			end
		end

		require("competitest.editor").start_ui(bufnr, tcnum, tctbl[tcnum].input, tctbl[tcnum].output, save_data, api.nvim_get_current_win())
	end

	if tcnum == "" then
		require("competitest.picker").start_ui(bufnr, tctbl, "Edit a Testcase", start_editor, api.nvim_get_current_win())
	else
		start_editor({ id = tonumber(tcnum) })
	end
end

---Delete a testcase
---@param tcnum integer: testcase number
function M.delete_testcase(tcnum)
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr) -- reload buffer configuration since it may have been updated in the meantime
	local tctbl = testcases.get_testcases(bufnr)

	local function delete_testcase(item) -- item.id is testcase number
		if not tctbl[item.id] then
			utils.notify("delete_testcase: testcase " .. tostring(item.id or tcnum) .. " doesn't exist!")
			return
		end
		tcnum = item.id

		local choice = vim.fn.confirm("Are you sure you want to delete Testcase " .. tcnum .. "?", "&Yes\n&No")
		if choice == 2 then
			return
		end -- user chose "No"

		if config.get_config(bufnr).testcases_use_single_file then
			tctbl[tcnum] = nil
			testcases.write_testcases_on_single_file(bufnr, tctbl)
		else
			testcases.write_testcase_on_files(bufnr, tcnum)
		end
	end

	if tcnum == "" then
		require("competitest.picker").start_ui(bufnr, tctbl, "Delete a Testcase", delete_testcase, api.nvim_get_current_win())
	else
		delete_testcase({ id = tonumber(tcnum) })
	end
end

---Convert testcases from single file to multiple files and vice versa
---@param mode string: can be "singlefile_to_files", "files_to_singlefile" or "auto"
function M.convert_testcases(mode)
	local bufnr = api.nvim_get_current_buf()
	local singlefile_tctbl = testcases.load_testcases_from_single_file(bufnr)
	local no_singlefile = next(singlefile_tctbl) == nil
	local files_tctbl = testcases.load_testcases_from_files(bufnr)
	local no_files = next(files_tctbl) == nil

	local function convert_singlefile_to_files()
		if no_singlefile then
			utils.notify("convert_testcases: there's no single file containing testcases.")
			return
		end
		if not no_files then
			local choice = vim.fn.confirm("Testcases files already exist, by proceeding they will be replaced.", "&Proceed\n&Cancel")
			if choice == 2 then
				return
			end -- user chose "Cancel"
		end

		for tcnum, _ in pairs(files_tctbl) do -- delete already existing files
			testcases.write_testcase_on_files(bufnr, tcnum)
		end
		testcases.write_testcases_on_single_file(bufnr, {}) -- delete single file
		for tcnum, tc in pairs(singlefile_tctbl) do -- create new files
			testcases.write_testcase_on_files(bufnr, tcnum, tc.input, tc.output)
		end
	end

	local function convert_files_to_singlefile()
		if no_files then
			utils.notify("convert_testcases: there are no files containing testcases.")
			return
		end
		if not no_singlefile then
			local choice = vim.fn.confirm("Testcases single file already exists, by proceeding it will be replaced.", "&Proceed\n&Cancel")
			if choice == 2 then
				return
			end -- user chose "Cancel"
		end

		for tcnum, _ in pairs(files_tctbl) do -- delete already existing files
			testcases.write_testcase_on_files(bufnr, tcnum)
		end
		testcases.write_testcases_on_single_file(bufnr, files_tctbl) -- create new single file
	end

	if mode == "singlefile_to_files" then
		convert_singlefile_to_files()
	elseif mode == "files_to_singlefile" then
		convert_files_to_singlefile()
	elseif mode == "auto" then
		if no_singlefile and no_files then
			utils.notify("convert_testcases: there's nothing to convert.")
		elseif not no_singlefile and not no_files then
			utils.notify("convert_testcases: single file and testcases files exist, please specifify what's to be converted.")
		elseif no_singlefile then
			convert_files_to_singlefile()
		else
			convert_singlefile_to_files()
		end
	else
		utils.notify("convert_testcases: unrecognized mode '" .. tostring(mode) .. "'.")
	end
end

M.runners = {} -- runners associated with a buffer

---Unload a runner (called on BufUnload)
function M.remove_runner(bufnr)
	M.runners[bufnr] = nil
end

---Start testcases runner
---@param testcases_list string: string with integers representing testcases to run, or empty string to run all the testcases
---@param compile boolean: whether to compile or not
---@param only_show boolean: if true show previously closed CompetiTest windows without executing testcases
function M.run_testcases(testcases_list, compile, only_show)
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr)
	local tctbl = testcases.get_testcases(bufnr)

	if testcases_list ~= "" then
		local new_tctbl = {}
		testcases_list = vim.split(testcases_list, " ", { trimempty = true })
		for _, tcnum in ipairs(testcases_list) do
			local num = tonumber(tcnum)
			if not num or not tctbl[num] then -- invalid testcase
				utils.notify("run_testcases: testcase " .. tcnum .. " doesn't exist!")
			else
				new_tctbl[num] = tctbl[num]
			end
		end
		tctbl = new_tctbl
	end

	if not M.runners[bufnr] then -- no runner is associated to buffer
		M.runners[bufnr] = require("competitest.runner"):new(api.nvim_get_current_buf())
		if not M.runners[bufnr] then -- an error occurred
			return
		end
		-- remove runner data when buffer is unloaded
		api.nvim_command("autocmd BufUnload <buffer=" .. bufnr .. "> lua require('competitest.commands').remove_runner(vim.fn.expand('<abuf>'))")
	end
	local r = M.runners[bufnr] -- current runner
	if not only_show then
		r:kill_all_processes()
		r:run_testcases(tctbl, compile)
	end
	r:set_restore_winid(api.nvim_get_current_win())
	r:show_ui()
end

function M.receive_testcases()
	local bufnr = api.nvim_get_current_buf()
	config.load_buffer_config(bufnr)
	require("competitest.receive").start_receiving(bufnr)
end

return M
