fx_version 'cerulean'
game 'gta5'

lua54 'yes'
author 'ludibelles'
description 'Tabletop combat action log — dice rolling, turn timers, Discord logging, NUI tracker'
version '1.0.0'

shared_script 'config.lua'
server_script  'server.lua'
client_script  'client.lua'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}
