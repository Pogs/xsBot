function splitnick(host)
	return host:match"^:?([^!]*)"
end
function lower(s)
	return s:lower():gsub("[{}|~]",{["{"]="[",["}"]="]",["|"]="\\",["~"]="^"})
end
function allowed(network,channel,host,command)
	local level,found=0
	for name,hostmasks in pairs(config.servers[network].hosts) do
		for _,hostmask in ipairs(hostmasks) do
			if lower(host):match(hostmask) then
				level=config.servers[network].channels[channel] and config.servers[network].channels[channel].access[name] or config.servers[network].access[name] or config.access[name]
				found=true
				break
			end
		end
		if found then
			break
		end
	end
	return (level or 0)>=(config.level[lower(command)] or 1/0)
end

push =
	function (t, ...)
		for i = 1, select('#', ...) do
			local v = select(i, ...)

			table.insert(t, v)
		end

		return t
	end

squote =
	function (s)
		return [[']] .. s:gsub([[']], [[\']]) .. [[']]
	end

tolua =
	function (...)
		local s = {}

		for i = 1, select('#', ...) do
			local v = select(i, ...)
			local t = type(v)

			-- ordered by most common (guessing)
			if     t == 'string'   then table.insert(s, squote(v))
			elseif t == 'function' then table.insert(s, 'function')
			elseif t == 'table'    then table.insert(s, '{?}')
			elseif t == 'thread'   then table.insert(s, 'thread')
			else                        table.insert(s, tostring(v))
			end
		end

		return table.concat(s, ', ')
	end

http =
	function (url, timeout)
		local c = socket.tcp()

		c:settimeout(timeout or 3)

		if url:match('http://') then
			url = url:sub(7)
		end

		-- hardcoded port might be bad. T.T
		if not c:connect(url:match('^[^/:]+'), 80) then
			return
		end

		c:send
		(
			string.format
			(
				'Get %s HTTP/1.1\r\n' ..
				'Host: %s\r\n' ..
				'Connection: close\r\n' ..
				'\r\n',
				url:match('/.*$') or '/',
				url:match('^[^/:]+')
			)
		)

		local d = c:receive('*a')

		if not d then
			return
		end

		local h, o = nil, nil
		do 
			local s, e = d:find('\r?\n\r?\n')
			h = d:sub(1, s - 1)
			o = d:sub(1, e + 1)
		end

		-- not needed anymore.. ~
		d = nil

		if h:upper():find('TRANSFER%-ENCODING:%s+CHUNKED%s*\r?\n') then
			local s = {}
			local i = 1

			while true do
				if #s > 255 then
					s = { table.concat(s) }
				end

				-- 32KiB
				assert(#s[1] < 32768, 'LOL')

				local n = o:match('(%x+)\r\n', i)

				assert(n, 'malformed http chunk; invalid or missing size')

				-- advance past: 2F\r\n (example)
				i = i + #n + 2

				-- this will always succeed
				n = tonumber(n, 16)

				-- last chunk reached, we don't even
				-- care about the trailing '\r\n'
				if n == 0 then
					break
				end

				local tmp = o:match('.*\r\n', i)

				assert(tmp, 'malformed http chunk; no data for size')

				table.insert(s, tmp)

				-- advanced past: data\r\n (example)
				i = i + #tmp + 2
			end

			return table.concat(s)
		end

		return o
	end

_break =
	function ()
		loop_level = loop_level - 1
	end

checktype =
	function (types, values)
		for i,v in ipairs(types) do
			if values[i] == nil then
				error("a "..v.." expected!")
		elseif v=="number" then
			if not tonumber(values[i]) then
				error('"'..tostring(values[i])..'" doesnt look like a number to me')
			end
		elseif type(values[i])~=v then
			error("a "..v.." expected, got "..type(values[i]))
		end
	end
end

nstime =
	function ()
		local file = assert(io.popen'date +%s.%N')
		local time = assert(tonumber(file:read'*a'))

		file:close()

		return time
	end

do
	local last_used={}
	local function timedsend(network,channel,text)
		last_used[network]=last_used[network]or nstime()-1
		while last_used[network]>nstime()-config.servers[network].throttle do
			socket.sleep(config.servers[network].throttle/2)
		end
		send(network,"PRIVMSG",channel,text)
		last_used[network]=nstime()
	end
	function privmsg(network,channel,text)
		for i=1,#text,400 do
			timedsend(network,channel,text:sub(i,i+399))
		end
	end
end
function setmode(network,channel,mode,...)
	local args={...}
	local last="-"
	mode=mode:gsub("([+-])(.)",function(a,b)if #a>0 then last=a end return last..b end)
	for substr in mode:gmatch"[+-]?.[+-]?.?[+-]?.?[+-]?.?" do
		local subarg={}
		for i=1,4 do
			if #args>0 then
				table.insert(subarg,table.remove(args,1))
			end
		end
		send(network,"MODE",channel,substr,unpack(subarg))
	end
end
function whois(network,who)
	local users={}
	send(network,"WHO",who)
	loop(function(net,raw,sender,num,_,_,ident,host,server,nick,_,rname)
		if net==network then
			if num=="352" then
				table.insert(users,{ident=ident,host=host,server=server,nick=nick,rname=rname})
				return true
			elseif num=="315" then
				return false
			end
		end
	end)
	return users
end
