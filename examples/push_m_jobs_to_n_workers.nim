import threadproxy
import sugar

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
      asyncCheck proxy.send("master", "stop")
  waitFor proxy.poll()

proc workerMain(proxy: ThreadProxy) {.thread.} =
  # register action handler
  proxy.onData "fib":
    let x = data.getInt()
    echo proxy.name, " is processing ", x
    await proxy.send("collector", "result", %*{
      "name": proxy.name,
      "x": x,
      "y": fib(x)
    })

  # start processing channel
  waitFor proxy.poll()

proc main() =
  let proxy = newMainThreadProxy("master")
  proxy.onData "stop":
    proxy.stop()

  # create collector thread
  proxy.createThread("collector", collectorMain)

  # create N worker threads
  let N = 4
  for i in 0 ..< N:
    proxy.createThread("worker_" & $i, workerMain)

  # distribute M jobs to threads
  for x in 1..40:
    capture x:
      let name = "worker_" & $(x mod N)
      echo "push job ", x, " to ", name
      asyncCheck proxy.send(name, "fib", %x)

  # poll until proxy stop
  waitFor proxy.poll()

when isMainModule:
  main()