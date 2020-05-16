# ThreadProxy

Simplify Nim inter-thread communiccation.

## Overview 

This library is based on [threads](https://nim-lang.org/docs/threads.html) and [channels](https://nim-lang.org/docs/channels.html). 
Each thread is associated with one channel. Threads process its channel with asyncdispatcher.

Two communication patterns `send` and `ask` are provided. `send` is uni-directional which primary usage is to notify another thread. 
`ask` is bi-directional, request-and-reply style which functions like remote function call. 

Each thread has a name. All threads can talk with each other by name reference. 

The only data exchange format is `json`.

## Example 

```nim
import threadproxy, sugar

proc fib(x: int): int = 
  if x <= 1: 1 
  else: fib(x-1) + fib(x-2)

proc workerMain(proxy: ThreadProxy) {.thread.} =
  echo proxy.name, " is running"

  # register action handler
  proxy.onData "fib":
    let x = data.getInt()
    echo proxy.name, " is finding fib(", x, ")"
    let y = fib(x)
    result = %*{
      "name": proxy.name,
      "input": x,
      "output": y
    }

  # start processing channel
  asyncCheck proxy.poll()

  # do other async task here
  
  runForever()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create N threads
  let N = 4
  for i in 0..<N:
    proxy.createThread("worker_" & $i, workerMain)

  # distribute M jobs to threads randomly
  let M = 40
  var done = 0
  for x in 1..M:
    capture x:
      let future = proxy.ask("worker_" & $(x mod N), "fib", %x)
      future.addCallback:
        if future.failed:
          let err = future.readError()
          echo err.msg
        else:
          let json = future.read
          let name = json["name"].getStr()
          let x = json["input"].getInt()
          let y = json["output"].getInt()
          echo name, " found fib(", x, ") = ", y
        done += 1

  while done < M: poll()

when isMainModule:
  main()
```



