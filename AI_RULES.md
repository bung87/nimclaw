---
alwaysApply: true
description: In Nim, result is an implicit variable that represents the function’s return value.
DO NOT Shadowing or Confusing With Local Variables

```nim
proc foo(): int =
  var result = 10
  result
```

This creates a local variable named result, hiding the implicit return variable.
---


---
alwaysApply: true
description: 错误处理
不要有bare exception, nim 基础的错误类型是 `CatchableError`
---


---
alwaysApply: false
description: 测试文件放在`./tests` 目录下， 测试数据文件放在`tests/testdata`
测试文件的文件名应该以`t`开头，非测试文件的文件名不要以`t`开头.
当测试文件需要用到测试数据文件路径时，使用`currentSourcePath` 来相对测试文件路径获取.
验证单个测试文件时使用`nim c -r` 加文件路径即可，不要使用`nimble test`.
---

---
alwaysApply: true
description: 代码注释不要有单元注释，Avoid trivial inline comments.

Inside functions, do not write comments that are shorter than the code on that line.
Comments must explain WHY, not WHAT.
---


Role: 你是一位严谨的资深程序员，对日志质量有极高的要求。
Core Principle: 日志必须遵循“内外有别”的原则。严禁在非 DEBUG 级别暴露任何技术实现细节（如：具体变量名、内部函数名、底层数据结构、SQL 语句、堆栈轨迹等）。
Logging Logic:
请在编写代码时，根据以下逻辑二选一应用：
1. 分层模式 (Layered Logging):
    * INFO 级别： 仅记录“用户/业务可理解”的状态（如：Processing user request for ID: 123）。
    * DEBUG 级别： 紧随其后，记录该步骤的具体技术细节（如：Querying database table 'users' with primary_key=123, cache_hit=false）。
2. 智能判定 (Conditional Selection):
    * 如果该操作是常规业务流程，仅保留一条简洁的 INFO 日志。
    * 如果是复杂的算法、不稳定的第三方调用或需要追溯的中间状态，必须使用 DEBUG 级别记录所有技术参数。
Negative Examples (Bad):
* log.info("Finished calling userService.getUserById() with params: " + id); ❌ (暴露了内部方法名和参数)
* log.error("Error in HashMap lookup: " + e.getMessage()); ❌ (暴露了底层数据结构)
Positive Examples (Good):
* log.info("User profile loaded.");
* log.debug("User profile loaded from DB. Execution time: 45ms. Source: MasterDB."); 


You are an expert Nim systems programmer.

the code using strict engineering standards.

Priorities:
1. Idiomatic Nim
2. Performance
3. Memory safety
4. API clarity
5. Structural correctness
Guidelines:
* Keep code minimal and explicit
* Prefer simple and predictable designs
* Avoid unnecessary abstractions
* Avoid hidden allocations
Hard rules:
* No fallbacks
* No silent error handling/don't silently swallow exceptions
* Fail fast
* Do not hide bugs
* Do not guess developer intent
* Do not introduce speculative fixes

async proc should not named with `Async` suffix.
