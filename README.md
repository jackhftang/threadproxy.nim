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

## Usage 

The general pattern should look like the following.

```nim
import threadproxy

proc fooMain(proxy: ThreadProxy) {.thread.} =
  # setup and poll threadProxy
  proxy.onData "action1": result = action1(data)
  proxy.onData "action2": result = action2(data)
  # ... 
  asyncCheck proxy.poll()

  # ... 
  # do something here
  # ... 
  
  runForever()

proc main() =
  # create, setup and poll mainThreadProxy
  let proxy = newMainThreadProxy("main")
  proxy.onData "action1": result = action1(data)
  proxy.onData "action2": result = action2(data)
  # ...
  asyncCheck proxy.poll()

  proxy.createThread("foo1", fooMain)
  proxy.createThread("foo2", fooMain)
  #... 

  # ...
  # do something here
  # ...

  runForever()

when isMainModeul:
  main()
```

## Examples

**Example 1:** Distribute M jobs to N workers.

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
      proxy.ask(name, "fib", %x).addCallback:
        # for demo, ignore future.failed here
        let y = future.read
        echo name, ": fib(", x, ") = ", y
        done += 1

  while done < M: poll()

when isMainModule:
  main()
```

## Manually Create Thread


## API 

see [here](https://jackhftang.github.io/threadproxy.nim/)


