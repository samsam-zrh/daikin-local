#!/bin/zsh
cd -- "${0:A:h}" || exit 1
/usr/bin/python3 server.py --open
