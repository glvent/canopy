version = "0.1.0"
author = "Canopy contributors"
description = "Native Nim immediate-mode terminal UI library"
license = "MIT"
srcDir = "src"
installExt = @["nim", "txt"]
requires "nim >= 2.2.0"

task test, "Run native Nim tests (no Rust required)":
  exec "nim r --path:src tools/tester.nim"

task examples, "Compile all examples":
  exec "nim r --path:src tools/tester.nim examples"

task bench, "Run native benchmarks":
  exec "nim c -r -d:release --path:src benchmarks/benchmarks.nim"
  exec "nim c -r -d:release --path:src --out:build/animation_benchmarks benchmarks/animation_benchmarks.nim"
  exec "nim c -r -d:release --path:src --out:build/interaction_benchmarks benchmarks/interaction_benchmarks.nim"

task docs, "Generate API documentation":
  exec "nim doc --project --index:on --path:src --outdir:build/docs src/canopy.nim"
  exec "nim doc --index:on --path:src --outdir:build/docs src/canopy/runtime/terminal/input.nim"
  exec "nim doc --index:on --path:src --outdir:build/docs src/canopy/runtime/terminal/parser.nim"
  exec "nim doc --index:on --path:src --outdir:build/docs src/canopy/runtime/terminal/events.nim"
  exec "nim doc --project --index:on --path:src --outdir:build/docs/animation src/canopy/ui/animation/index.nim"
  exec "nim doc --project --index:on --path:src --outdir:build/docs/controls src/canopy/ui/controls/index.nim"
