platform "coro-webserver"
    requires { Model } { respond! : Request => Response }
    exposes [
        Sleep,
    ]
    packages {}
    imports []
    provides [respondBoxed!]

Request : Str
Response : Str

respondBoxed! : Request => Response
respondBoxed! = \request ->
    respond! request
