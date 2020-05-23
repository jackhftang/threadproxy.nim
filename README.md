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
- The order of creation of threads does not matter, as long as the opposite thread is running at the time of calling `send` or `ask`.

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

  # create threads
  proxy.createThread("foo1", fooMain)
  proxy.createThread("foo2", fooMain)
  #... 

  # ...
  # do other things here
  # ...

  runForever()

when isMainModeul:
  main()
```

## Examples

**Example 1:** simple `ask`

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

**Example 2:** N workers pull M jobs

```nim

```

see **/examples** for more examples

## Manually Create Thread

If you want to pass something into the starting procedure of threads, you need to call `createToken` in main thread and then `createProxy` in the child threads.

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


