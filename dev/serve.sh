#!/bin/sh

# You may need to remove localhost from the OpenComputers blacklist
exec python3 -m http.server --directory ../src 40000
