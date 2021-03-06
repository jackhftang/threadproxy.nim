# ThreadProxy

Simplify Nim Inter-Thread Communication

## Overview 

ThreadProxy help you manage threads and channels. You don't have to declare them explicitly. 
ThreadProxy also provide a little thread-name-system and do name resolution for you. 

Some key-points:

- JSON is the *ONLY* data exchange format.
- Each thread has a unique `name` assigned at creation.
- Each thread can register a handle on action with `on(...)`
- Each thread start processesing its messages with `poll()`.
- Threads can talk with each other with `name` reference. 
- Threads can talk with each other in one-way with `send(...): Future[void]`.
- Threads can talk with each other in two-way with `ask(...): Future[JsonNode]`.
- The order of creation of threads does not matter as long as the target thread is running at the time of calling `send` or `ask`.

Internally:

- After 0.2.0, each thread is associated with two channels. One is for internal messages that need to preempt other messages. The other one is for normal messages.

## Usage 

The typical pattern should look like the following.

```nim
import threadproxy                                    # ---- 1

proc fooMain(proxy: ThreadProxy) {.thread.} =         # ---- 2 
  # setup and then poll threadProxy
  proxy.on "action1", proc(data: JsonNode): Future[JsonNode] {.gcsafe.} =   # ---- 3 
    result = action1(data)
  
  proxy.onData "action2":                             # ---- 4
    result = action2(data)

  proxy.onDefault proc(action: string, data: JsonNode): Future[JsonNode] {.gcsafe.} =  # ---- 5
    reuslt = ...

  # ... 
  asyncCheck proxy.poll()                             # ---- 6

  # ... 
  # do something here
  # ... 
  
  runForever()

proc main() =
  # create, setup and then poll mainThreadProxy
  let proxy = newMainThreadProxy("main")              # ---- 7
  proxy.onData "action1": result = action1(data)      # ---- 8
  proxy.onDefaultData: result = handler(action, data) 
  # ...
  asyncCheck proxy.poll()                             # ---- 9

  # create threads
  proxy.createThread("foo1", fooMain)                 # ---- 10
  proxy.createThread("foo2", fooMain)
  #... 

  # ...
  # do something here
  # ...

  runForever()

when isMainModeul:
  main()
```

1. `import threadproxy` will also `import json, asyncdispatch`. They are almost always used together.
2. Define an entry function for threads. The argument have to be a `ThreadProxy` unless you want to create thread manually. Also note that the `{.thread.}` pragma must be present.
3. Define a handler for `action`. The handler function is responsible for both `send` and `ask` handling. A `nil` return value will be converted to `JNull`
4. `onData` is a template version of `on`. It saves you from typing `proc...` everytime. The argument `data` is injected and so the name on**Data**
5. Default handler for all unregistered actions. There is also a template version `onDefaultData` that work similarly. Only the last *ONE* default hanlder is registered.
6. Start processing messages on channels asychronously. This must be called exactly once. If poll is not called, nothing will happen. If it is called more than one time during running, a `PollConflictError` will raise.
7. Create a `MainThreadProxy` with a name.  `MainThreadProxy` is also a `ThreadProxy` but with responsibilities to handle threads and channels. 
8. Define handlers for MainThreadProxy similar to that in fooMain.
9. Start processing messages similar to that in fooMain.
10. Create thread with a name and entry function.

## Examples

Example 1: simple ask

```nim
import threadproxy

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "sum":
    var x = 0
    for n in data:
      x += n.getInt()
    return %x

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  asyncCheck proxy.poll()

  # create worker thread
  proxy.createThread("worker_0", workerMain)

  # ask worker_0 to double 10
  let answer = waitFor proxy.ask("worker_0", "sum", %[2,3,5,7])
  assert answer == %17

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

see [/examples](/examples) for more examples.

## Manually Create Thread

If you want to pass more things into the main procedure of threads, you need to generate a token by calling `createToken` in mainThreadProxy and then pass the token to the main procedure and then call `newThreadProxy` in that threads.

Example

```nim
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

  # NOTE: You are responsible to make sure that
  # the variable workerThread live longer than the thread itself
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


