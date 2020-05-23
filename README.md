# ThreadProxy

Simplify Nim Inter-Thread Communication

## Overview 

- Each thread has a fixed unique `name`.
- Each thread is associated with one [`Channel`](https://nim-lang.org/docs/channels.html). 
- Each thread processes its channel with `poll`.
- JSON is the data exchange format.
- Threads can talk with each other with `name` reference. 
- Threads can talk with each other in uni-directional with `send`.
- Threads can talk with each other in two-directional way with `ask`.
- The order of creation of threads does not matter as long as the target thread is running at the time of calling `send` or `ask`.

## Usage 

The general pattern should look like the following.

```nim
import threadproxy

proc fooMain(proxy: ThreadProxy) {.thread.} =
  # setup and then poll threadProxy
  proxy.onData "action1": result = action1(data)
  proxy.onData "action2": result = action2(data)
  # ... 
  asyncCheck proxy.poll()

  # ... 
  # do something here
  # ... 
  
  runForever()

proc main() =
  # create, setup and then poll mainThreadProxy
  let proxy = newMainThreadProxy("main")
  proxy.onData "action1": result = action1(data)
  proxy.onData "action2": result = action2(data)
  # ...
  asyncCheck proxy.poll()

  # create threads
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

Example 1: simple ask

```nim
import threadproxy, asyncdispatch

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "double":
    let x = data.getInt()
    return %(2*x)

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create worker thread
  proxy.createThread("worker_0", workerMain)

  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "double", %10)
  assert answer == %20

when isMainModule:
  main()
```

Example 2: pulling M jobs from N workers and collect result in collector

```nim
import threadproxy, deques

const M = 40

proc fib(x: int): int = 
  if x <= 1: 1 
  else: fib(x-1) + fib(x-2)

proc collectorMain(proxy: ThreadProxy) {.thread.} =
  var done = 0
  proxy.onData "result":
    let name = data["name"].getStr()
    let x = data["x"].getInt()
    let y = data["y"].getInt()
    echo "collector receive job ", x, " result from ", name, " fib(", x, ") = ", y
    done += 1
    if done >= M:
      # all done
      asyncCheck proxy.send("master", "stop")
  waitFor proxy.poll()

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # start processing channel
  asyncCheck proxy.poll()

  proc process() {.async.} =
    let job = await proxy.ask("master", "job")
    if job.kind == JNull: 
      # no more job
      proxy.stop()
    else:
      # process job
      let x = job.getInt()
      echo proxy.name, " is finding fib(", x, ")"
      await proxy.send("collector", "result", %*{
        "name": proxy.name,
        "x": x,
        "y": fib(x)
      })

  while proxy.isRunning:
    waitFor process()

proc main() =
  # prepare jobs
  var jobs = initDeque[int]()
  for i in 1..M: jobs.addLast i

  # create and setup MainThreadProxy
  let proxy = newMainThreadProxy("master")

  proxy.onData "stop": proxy.stop()
  
  proxy.onData "job":
    if jobs.len > 0:
      result = %jobs.popFirst
    else:
      # return null if no more job
      result = newJNull()

  # create collector thread
  proxy.createThread("collector", collectorMain)
  
  # create N threads
  let N = 4
  for i in 0 ..< N:
    proxy.createThread("worker_" & $i, workerMain)

  # poll until proxy stop
  waitFor proxy.poll()

when isMainModule:
  main()
```

see **/examples** for more examples

## Manually Create Thread

If you want to pass more things into the main procedure of threads, you need to generate a token by calling `createToken` in mainThreadProyx and then pass the token to the main procedure and then call `createProxy` in that threads.

Example

```
import threadproxy, asyncdispatch

type
  WorkerThreadArgs = object
    multiplier: int
    token: ThreadToken

proc workerMain(args: WorkerThreadArgs) {.thread.} =
  let proxy = newThreadProxy(args.token)

  # register action handler
  proxy.onData "multiply":
    let x = data.getInt()
    return %(args.multiplier*x)

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create thread token
  let token = proxy.createToken("worker_0")

  var workerThread: Thread[WorkerThreadArgs]
  createThread(workerThread, workerMain, WorkerThreadArgs(
    multiplier: 3,
    token: token
  ))


  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "multiply", %10)
  assert answer == %30

when isMainModule:
  main()
```

## API 

see [here](https://jackhftang.github.io/threadproxy.nim/)


