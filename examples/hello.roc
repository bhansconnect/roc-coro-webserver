app [respond!] { server: platform "../platform/main.roc" }

import server.Sleep

respond! = \_ ->
    Sleep.millis! 200
    "Hello, World"
