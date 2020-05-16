# ThreadProxy

Simplify Nim inter-thread communiccation.

## Overview 

This library is based on [threads](https://nim-lang.org/docs/threads.html) and [channels](https://nim-lang.org/docs/channels.html). 
Each thread is associated with one channel. Threads process its channel with asyncdispatcher.

Two communication patterns are provided:
- `send` is uni-directional, sending data to channel of target thread.
- `ask` is bi-directional, request-and-reply style with returning type `Future[JsonNode]`, use like remote procedure call. 

Each thread has a fixed unique `name`. All threads can talk with each other by name. The order of creation of threads does not matter, as long as the target thread is created before calling `send` or `ask`.

The only data exchange format is `json`.

## Example 

```nim
import threadproxy, sugar

proc fib(x: int): int = 
  if x <= 1: 1 
  else: fib(x-1) + fib(x-2)

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "fib":
    let x = data.getInt()
    return %fib(x)

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create N threads
  let N = 4
  for i in 0 ..< N:
    proxy.createThread("worker_" & $i, workerMain)

  # distribute M jobs to threads
  let M = 40
  var done = 0
  for x in 1..M:
    capture x:
      let name = "worker_" & $(x mod N)
      let future = proxy.ask(name, "fib", %x)
      future.addCallback:
        let y = future.read
        echo name, ": fib(", x, ") = ", y
        done += 1

  while done < M: poll()

when isMainModule:
  main()
```

## Manually Create Thread




