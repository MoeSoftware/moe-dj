fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'moe-dj'
author 'Moe'
description 'Moe DJ — framework-agnostic (QBCore / Qbox / ESX / pure standalone).'
version '1.0.0'
license 'MIT'
repository 'https://github.com/MoeSoftware/moe-dj'
url 'https://www.moesoftware.com/'

ui_page 'html/index.html'

shared_script 'config.lua'

server_scripts {
    'server/permissions.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
    'client/manager.lua',
    'client/dui.lua',
}

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/audio.js',
    'html/screen.html',
    'html/screen.css',
    'html/screen.js',
}
