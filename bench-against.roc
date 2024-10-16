app [Model, server] { pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.9.0/taU2jQuBf-wB8EJb0hAkrYLYOGacUU5Y9reiHG45IY4.tar.br" }

import pf.Sleep
import pf.Http exposing [Request, Response]

Model : {}

server = { init: Task.ok {}, respond }

respond : Request, Model -> Task Response [ServerErr Str]_
respond = \_req, _ ->
    # This is the costly part, sleep for a bit (pretend this is some server web request)
    # Sleep 20ms

    Sleep.millis! 20

    Task.ok { status: 200, headers: [], body: Str.toUtf8 "Hello, World!" }
