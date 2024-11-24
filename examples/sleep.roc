app [respond!] { server: platform "../platform/main.roc" }

import server.Sleep

respond! = \_ ->
    Sleep.millis! 50
    Sleep.millis! 50
    Sleep.millis! 50
    "Hello, World!"
