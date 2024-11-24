app [respond!] { server: platform "../platform/main.roc" }

import server.Sleep

respond! = \_ ->
    Sleep.millis! 20
    # This takes about 1-5ms of compute.
    x = fact 1000000
    if x == 12 then
        "Goodbye, World!"
    else
        "Hello, World!"

fact = \n ->
    helper = \a, x ->
        if x == 1 then
            a
        else
            Num.mulWrap a x
            |> helper (x - 1)

    helper n (n - 1)

