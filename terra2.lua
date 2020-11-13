
local t2 = {}

local function expression_function(lx)

	local cur = lx.cur
	local next = lx.next
	local nextif = lx.nextif
	local expect = lx.expect
	local expectval = lx.expectval
	local errorexpected = lx.errorexpected
	local line = lx.line
	local luaexpr = lx.luaexpr

	local function isend() --check for end of block
		local tk = cur()
		return tk == 'else' or tk == 'elseif' or tk == 'end'
			or tk == 'until' or tk == '<eof>'
	end

	local priority = {
		['^'  ] = {11,10},
		['*'  ] = {8,8},
		['/'  ] = {8,8},
		['%'  ] = {8,8},
		['+'  ] = {7,7},
		['-'  ] = {7,7},
		['..' ] = {6,5},
		['<<' ] = {4,4},
		['>>' ] = {4,4},
		['==' ] = {3,3},
		['~=' ] = {3,3},
		['<'  ] = {3,3},
		['<=' ] = {3,3},
		['>'  ] = {3,3},
		['>=' ] = {3,3},
		['->' ] = {3,2},
		['and'] = {2,2},
		['or' ] = {1,1},
	}
	local unary_priority = 9 --priority for unary operators

	local function params() --(name:type,...[,...])
		local tk = expect'('
		if tk ~= ')' then
			repeat
				if tk == '<name>' then
					next()
					expect':' --type
					luaexpr()
				elseif tk == '...' then
					next()
					break
				else
					errorexpected'<name> or "..."'
				end
				tk = nextif','
			until not tk
		end
		expect')'
	end

	local function body(line, pos) --(params) [:return_type] block end
		params()
		if nextif':' then --return type
			luaexpr()
		end
		block()
		if cur() ~= 'end' then
			expectmatch('end', 'function', line, pos)
		end
		next()
	end

	local function name()
		return expectval'<name>'
	end

	local function type()
		luaexpr()
	end

	local function ref()
		if refs then
			push(refs, expectval'<name>')
		else
			expect'<name>'
		end
	end

	local function expr_field() --.:name
		next()
		name()
	end

	local function expr_bracket() --[expr]
		next()
		expr()
		expect']'
	end

	local function expr_table() --{[expr]|name=expr,;...}
		local line, pos = line()
		local tk = expect'{'
		while tk ~= '}' do
			if tk == '[' then
				expr_bracket()
				expect'='
			elseif tk == '<name>' and lookahead() == '=' then
				name()
				expect'='
			end
			expr()
			if not nextif',' and not nextif';' then break end
			tk = cur()
		end
		expectmatch('}', '{', line, pos)
	end

	local function expr_list() --expr,...
		expr()
		while nextif',' do
			expr()
		end
	end

	local function args() --(expr,...)|{table}|string
		local tk = cur()
		if tk == '(' then
			local line, pos = line()
			tk = next()
			if tk == ')' then --f()
			else
				expr_list()
			end
			expectmatch(')', '(', line, pos)
		elseif tk == '{' then
			expr_table()
		elseif tk == '<string>' then
			next()
		else
			errorexpected'function arguments'
		end
	end

	local function expr_primary() --(expr)|name .name|[expr]|:nameargs|args ...
		local iscall
		--parse prefix expression.
		local tk = cur()
		if tk == '(' then
			local line, pos = line()
			next()
			expr()
			expectmatch(')', '(', line, pos)
		elseif tk == '<name>' then
			ref()
		else
			error'unexpected symbol'
		end
		local tk = cur()
		while true do --parse multiple expression suffixes.
			if tk == '.' then
				expr_field()
				iscall = false
			elseif tk == '[' then
				expr_bracket()
				iscall = false
			elseif tk == ':' then
				next()
				name()
				args()
				iscall = true
			elseif tk == '(' or tk == '<string>' or tk == '{' then
				args()
				iscall = true
			else
				break
			end
			tk = cur()
		end
		return iscall
	end

	local function expr_simple() --literal|...|{table}|expr_primary
		local tk = cur()
		if tk == '<number>' or tk == '<imag>' or tk == '<int>' or tk == '<u32>'
			or tk == '<i64>' or tk == '<u64>' or tk == '<string>' or tk == 'nil'
			or tk == 'true' or tk == 'false' or tk == '...'
		then --literal
			next()
		elseif tk == '{' then --{table}
			expr_table()
		else
			expr_primary()
		end
	end

	--parse binary expressions with priority higher than the limit.
	local function expr_binop(limit)
		local tk = cur()
		if tk == 'not' or tk == '-' or tk == '#' then --unary operators
			next()
			expr_binop(unary_priority)
		else
			expr_simple()
		end
		local pri = priority[tk]
		while pri and pri[1] > limit do
			next()
			--parse binary expression with higher priority.
			local op = expr_binop(pri[2])
			pri = priority[op]
		end
		return tk --return unconsumed binary operator (if any).
	end

	function expr() --parse expression.
		expr_binop(0) --priority 0: parse whole expression.
	end

	local function assignment() --expr_primary,... = expr,...
		if nextif',' then --collect LHS list and recurse upwards.
			expr_primary()
			assignment()
		else --parse RHS.
			expect'='
			expr_list()
		end
	end

	local function label() --::name::
		next()
		name()
		local tk = expect'::'
		--recursively parse trailing statements: labels and ';' (Lua 5.2 only).
		while true do
			if tk == '::' then
				label()
			elseif tk == ';' then
				next()
			else
				break
			end
			tk = cur()
		end
	end

	--parse a statement. returns true if it must be the last one in a chunk.
	local function stmt()
		local tk = cur()
		if tk == 'if' then --if expr then block [elseif expr then block]... [else block] end
			local line, pos = line()
			next()
			expr()
			expect'then'
			block()
			while tk == 'elseif' do --elseif expr then block...
				next()
				expr()
				expect'then'
				block()
				tk = cur()
			end
			if tk == 'else' then --else block
				next()
				block()
			end
			expectmatch('end', 'if', line, pos)
		elseif tk == 'while' then --while expr do block end
			local line, pos = line()
			next()
			expr()
			expect'do'
			block()
			expectmatch('end', 'while', line, pos)
		elseif tk == 'do' then  --do block end
			local line, pos = line()
			next()
			block()
			expectmatch('end', 'do', line, pos)
		elseif tk == 'for' then
			--for name = expr, expr [,expr] do block end
			--for name,... in expr,... do block end
			local line, pos = line()
			next()
			name()
			local tk = cur()
			if tk == '=' then -- = expr, expr [,expr]
				next()
				expr()
				expect','
				expr()
				if nextif',' then expr() end
			elseif tk == ',' or tk == 'in' then -- ,name... in expr,...
				while nextif',' do
					name()
				end
				expect'in'
				expr_list()
			else
				errorexpected'"=" or "in"'
			end
			expect'do'
			block()
			expectmatch('end', 'for', line, pos)
		elseif tk == 'repeat' then --repeat block until expr
			local line, pos = line()
			next()
			block(false)
			expectmatch('until', 'repeat', line, pos)
			expr() --parse condition (still inside inner scope).
			exit_scope()
		elseif tk == 'terra' then --terra name body
			local line, pos = line()
			next()
			name()
			body(line, pos)
		elseif tk == 'var' then
			--var name1[:type1],...[=expr1],...
			local line, pos = line()
			next()
			repeat --name[:type],...
				name()
				if nextif':' then
					type()
				end
			until not nextif','
			if nextif'=' then -- =expr,...
				expr_list()
			end
		elseif tk == 'return' then --return [expr,...]
			tk = next()
			if not (isend(tk) or tk == ';') then
				expr_list()
			end
			return true --must be last
		elseif tk == 'break' then
			next()
		elseif tk == ';' then
			next()
		elseif tk == '::' then
			label()
		elseif tk == 'goto' then --goto name
			next()
			name()
		elseif not expr_primary() then --function call or assignment
			assignment()
		end
		return false
	end

	function block(do_exit_scope) --stmt[;]...
		--enter_scope()
		local islast
		while not islast and not isend() do
			islast = stmt()
			nextif';'
		end
		if do_exit_scope ~= false then
			--exit_scope()
		end
	end

	return function(_, kw, stmt)
		next()
		if kw == 'struct' then
			local name = stmt and expectval'<name>'
			expect'{'
			expect'}'
			return function(env)
				local s = {type = 'struct'}
				return s
			end, name and {name}
		elseif kw == 'terra' then
			local line, pos = line()
			local name = stmt and name()
			body(line, pos)
			return function(env)
				local f = {type = 'function'}
				return f
			end, name and {name}
		elseif kw == 'quote' then
		end
		assert(false)
	end
end

function t2.lang(lx)
	return {
		keywords = {'terra', 'quote', 'struct', 'var'},
		entrypoints = {
			statement = {'terra', 'struct'},
			expression = {'`'},
		},
		expression = expression_function(lx),
	}
end

return t2
