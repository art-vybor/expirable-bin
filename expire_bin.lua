-- Copyright 2014 Aerospike, Inc.

-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at

--    http://www.apache.org/licenses/LICENSE-2.0

-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- =========================================================================
-- UDF Bin Expiration Module
-- =========================================================================

-- This module provides basic functionality for bin level data expiration for the 
-- Aerospike database. This module uses special UDF bins that are specific to this
-- module and the bin expiration functionality will not be supported if used with
-- normal read/write operations. Also, this module does not fully remove data
-- from an expired bin for performance reasons so the data may still be accessible
-- through normal read/write operations. 

-- =========================================================================
-- USAGE
-- =========================================================================
--
-- Call the function through a client (See src/c and src/java) OR
-- Import module in lua:
-- local expbin = require("expire_bin");
-- eb.get(rec, bin);

-- =========================================================================
-- Debug Flags
-- =========================================================================
local GP;
local F = true;

-- =========================================================================
-- Config Variables
-- =========================================================================
local EXP_ID = "expbin_ttl";
local EXP_DATA = "data";

-- Type Checking Vars
local Map = getmetatable(map());

-- ========================================================================= 
-- Utility functions
-- ========================================================================= 

-- Check if bin is an expbin
local function is_expbin(bin)
	-- TODO: Test functionality
	if (bin ~= nil 
		and type(bin) == 'userdata' 
		and getmetatable(bin) == Map 
		and bin[EXP_ID] ~= nil) then
		return true;
	end
	return false;
end

-- Check if bin_ttl is valid for a given rec_ttl
local function valid_time(bin_ttl, rec_ttl)
	local meth = "valid_time";
	if (type(bin_ttl) ~= 'number' or (bin_ttl < 0 and bin_ttl ~= -1)) then
		GP=F and debug("<%s> bin_ttl is invalid", meth);
		return false;
	end
	if (rec_ttl == 0) then 
		return true;
	end
	if (bin_ttl == -1) then
		GP=F and debug("<%s> bin_ttl is invalid", meth);
		return false;
	end
	if (bin_ttl > rec_ttl) then
		GP=F and debug("<%s> bin_ttl is invalid", meth);
		return false;
	end
	return true;
end

-- Check whether bin_ttl has expired yet
local function not_expired(bin_ttl)
	if (bin_ttl ~= nil) then
		if (bin_ttl == -1 or os.time() <= bin_ttl) then
			return true;
		end
	end
	return false;
end

-- Get the bin value from an expbin if it hasn't expired
local function get_bin(bin_map)
	local meth = "get_bin";
	GP=F and debug("[ENTER]<%s> bin: %s", meth, tostring(bin_map));
	if (is_expbin(bin_map)) then
		if (not_expired(bin_map[EXP_ID])) then
			return bin_map[EXP_DATA];
		else
			GP=F and debug("[EXIT]<%s> Bin has expired, returning nil", meth);
			return nil;
		end
	else
		GP=F and debug("<%s> Bin is not an expbin.", meth);
		return bin_map;
	end
end

-- =========================================================================
-- get(): Get bin from record
-- =========================================================================
-- 
-- USAGE: as.execute(policy, key, "expire_bin", "get", bin);
--
-- Params:
-- (*) rec: record to retrieve bin from
-- (*) bin: bin names to retrieve from
--
-- Return:
-- 1 = error
-- list containing each respective bin value = success
-- =========================================================================
function get(rec, ...)
	local meth = "get";
	GP=F and debug("[BEGIN]<%s> bin:<%s>", meth, tostring(bin));
	if aerospike:exists(rec) then
		local return_list = list();
		-- Iterate through every bin request 
		for i,v in ipairs(arg) do
			local bin_map = rec[v];
			return_list[i] = get_bin(bin_map);
		end
		GP=F and debug("[EXIT]<%s> Returning bin list", meth);
		return return_list;
	else
		GP=F and debug("[EXIT]<%s> Record does not exist.", meth);
	end
end

-- =========================================================================
-- put(): Store bin to record
-- =========================================================================
--
-- USAGE: as.execute(policy, key, "expire_bin", "put", bin, val, bin_ttl, exp_create);
--
-- Params:
-- (*) rec: record to retrieve bin from
-- (*) bin: bin name 
-- (*) val: Value to store in bin
-- (*) bin_ttl: Bin TTL given in seconds or -1 to disable expiration
-- (*) exp_create: set to true to create new exp_bins
--
-- Return:
-- 1 = error
-- 0 = success
-- =========================================================================
function put(rec, bin, val, bin_ttl, exp_create)
	local meth = "put";
	GP=F and debug("[BEGIN]<%s> bin:%s value:%s ttl:%s", meth, bin, tostring(val), tostring(bin_ttl));
	if (rec[bin] == nil and not exp_create ) then
		GP=F and debug("%s : bin doesn't exist and expire bin creation disabled", meth);
		rec[bin] = val;
	else
		local map_bin = rec[bin];
		if (not is_expbin(map_bin)) then	
			map_bin = map();
		end 
		-- Create rec on server to get default server ttl
		local temp_rec = false;
		if not aerospike:exists(rec) then
			aerospike:create(rec);
			temp_rec = true;
		end
		if (not valid_time(bin_ttl, record.ttl(rec))) then
			GP=F and debug("%s : Record and Bin TTL conflict bin %s, rec %s", meth, tostring(bin_ttl), tostring(record.ttl(rec)));
			if (temp_rec) then
				aerospike:remove(rec);
			end
			return 1;
		end	
		if (bin_ttl ~= -1) then
			map_bin[EXP_ID] = bin_ttl + os.time();
		else
			map_bin[EXP_ID] = bin_ttl;
		end
		map_bin[EXP_DATA] = val;
		rec[bin] = map_bin;
	end
	if aerospike:exists(rec) then
		GP=F and debug("%s : Record updated", meth);
		local rc = aerospike:update(rec);
		GP=F and debug("JENE %s", tostring(rc));
	else
		GP=F and debug("%s : Record created", meth);
		aerospike:create(rec);
	end
	return 0
end

-- =========================================================================
-- puts(): Store bin to record
-- =========================================================================
--
-- USAGE: as.execute(policy, key, "expire_bin", "put", record_maps);
--
-- Params:
-- (*) rec: record to create/update bin to
-- (*) record_maps: list of maps containing the following fields
-- 	(*) bin: bin name 
-- 	(*) val: Value to store in bin
-- 	(*) bin_ttl: (optional) if provided, expire_bin will be created if none exists
--
-- Return:
-- 1 = error
-- 0 = success
-- =========================================================================
function puts(rec, ...)
	local meth = "puts";
	GP=F and debug("[BEGIN]<%s>", meth);
	for i,v in ipairs(arg) do
		local map_bin = v;
		local bin_ttl = map_bin[EXP_ID];
		local exp_create = false;
		if (bin_ttl == nil) then
			bin_ttl = -1;
		else 
			exp_create = true;
		end
		local return_val = put(rec, map_bin["bin"], map_bin["val"], bin_ttl, exp_create);
		if (return_val == 1) then
			return 1;
		end
	end
	return 0;
end

-- =========================================================================
-- touch(): Modify the bin's TTL
-- =========================================================================
--
-- USAGE: as.execute(policy, key, "expire_bin", "touch", bin, bin_maps);
--
-- Params:
-- (*) rec: record to retrieve bin from
-- (*) bin_maps: list of bin maps containing the following
-- 	(*) bin: bin names 
-- 	(*) bin_ttl: Bin TTL given in seconds or -1 to disable expiration
--
-- Return:
-- 0 = success
-- 1 = error
-- =========================================================================
function touch(rec, ...)
	local meth = "touch";
	GP=F and debug("[BEGIN]<%s>", meth);
	if aerospike:exists(rec) then
		for i,v in ipairs(arg) do
			local bin_map = v;
			local bin_name = bin_map["bin"]
			if (not valid_time(v["bin_ttl"], record.ttl(rec))) then 
				GP=F and debug("%s : Record TTL is less than Bin TTL for bin %s", meth, bin_name);
				return 1;
			else
				local rec_map = rec[bin_name];
				if (is_expbin(rec_map)) then
					if (bin_map["bin_ttl"] ~= -1) then
						rec_map[EXP_ID] = bin_map["bin_ttl"] + os.time();
					else
						rec_map[EXP_ID] = -1;
					end
				else
					GP=F and debug("expire_bin.%s : Bin %s is not a valid expbin", meth, bin_name);
					return 1;
				end
			end	
		end
		aerospike:update(rec);
		return 0;
	end
	GP=F and debug("expire_bin.%s : Record doesn't exist", meth);
	return 1;
end

-- =========================================================================
-- clean_bin(): Empty expired bins
-- =========================================================================
--
-- Params:
-- (*) rec: record to retrieve bin from
-- (*) bin: bins to clean 
--
-- Return:
-- 0 = success
-- 1 = error
-- =========================================================================
function clean(rec, ...)
	local meth = "clean";
	GP=F and debug("[BEGIN]<%s> ", meth);
	if aerospike:exists(rec) then
		for i,v in ipairs(arg) do
			local bin = v;
			local temp_bin = rec[bin];
			if (is_expbin(temp_bin) and not not_expired(temp_bin[EXP_ID])) then
				rec[bin] = nil;
				GP=F and debug("expire_bin.%s : Bin %s expired, erasing bin", meth, bin);
			else
				GP=F and debug("expire_bin.%s : Bin %s hasn't expired, skipping record", meth, bin);
			end
		end
		aerospike:update(rec);
		return 0;
	else
		GP=F and debug("expire_bin.%s : Record doesn't exist", meth);
		return 1;
	end
end

-- =========================================================================
-- ttl(): Get bin ttl
-- =========================================================================
--
-- Params:
-- (*) rec: record to retrieve bin from
-- (*) bin: bin to check
--
-- Return:
-- time to live in seconds = success
-- nil = error
-- =========================================================================
function ttl(rec, bin)
	local meth = "ttl";
	GP=F and debug("[BEGIN]<%s> bin:%s ", meth, bin);
	if aerospike:exists(rec) then
		local binMap = rec[bin];
		if (is_expbin(binMap)) then
			return binMap[EXP_ID];
		else
			GP=F and debug("[ERROR]<%s> Bin isn't an expire bin", meth);
		end
	else
		GP=F and debug("[ERROR]<%s> Record doesn't exist", meth);
		return nil;
	end
end

-- =========================================================================
-- Module export
-- =========================================================================
return {
	get   = get,
	put   = put,
	puts  = puts,
	touch = touch,
	clean = clean,
	ttl = ttl
	-- uncomment to test
	,is_expbin = is_expbin,
	valid_time = valid_time,
	not_expired = not_expired,
	get_bin = get_bin
}