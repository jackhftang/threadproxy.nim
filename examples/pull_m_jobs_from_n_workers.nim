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