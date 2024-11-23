module [
    millis!,
]

import Effects

## Sleep for at least the given number of milliseconds.
##
millis! : U64 => {}
millis! = \n ->
    Effects.sleepMillis! n
