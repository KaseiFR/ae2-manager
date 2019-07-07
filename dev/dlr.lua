-- Download and run

local shell = require('shell')

local args = table.pack(...)
local program = table.remove(args, 1):gsub('%.lua$', '')

shell.execute('wget http://localhost:40000/'..program..'.lua -f')
shell.execute(program, nil, table.unpack(args))
