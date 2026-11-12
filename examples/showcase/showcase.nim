## Canopy showcase: every widget, styling, layout, animation and input feature in one
## interactive app. Run it in a real terminal from the repository root:
##
##   nim r examples/showcase/showcase.nim
##   nim r examples/showcase/showcase.nim --inline   # inline viewport in normal scrollback
##   nim r examples/showcase/showcase.nim --square   # square tabs if rounded ends show boxes
##
## Each page lives in its own module and exposes `help`, `render`, `handle` and `update`.
import std/[os, monotimes, times]

import canopy
import canopy/runtime/terminal/input
import canopy/ui/animation/index as animation
import common, recording, inline_demo
import widgets_page, charts_page, text_page, motion_page, jobs_page, input_page, controls_page

const pageNames = ["Widgets", "Charts", "Text & color", "Motion", "Jobs", "Input", "Controls"]

var
  page = 0
  tabHits: array[pageNames.len, Rect]
  contentArea: Rect
  pageTransition: Transition
  frames = 0
  cellUpdates = 0
  screen: Size

proc pageHelp(): string =
  case page
  of 0: widgets_page.help
  of 1: charts_page.help
  of 2: text_page.help
  of 3: motion_page.help
  of 4: jobs_page.help
  of 5: input_page.help
  else: controls_page.help

proc renderPage(frame: var Frame, area: Rect) =
  case page
  of 0: widgets_page.render(frame, area)
  of 1: charts_page.render(frame, area)
  of 2: text_page.render(frame, area)
  of 3: motion_page.render(frame, area)
  of 4: jobs_page.render(frame, area)
  of 5: input_page.render(frame, area)
  else: controls_page.render(frame, area)

proc handlePage(event: input.Event): bool =
  case page
  of 0: widgets_page.handle(event)
  of 1: charts_page.handle(event)
  of 2: text_page.handle(event)
  of 3: motion_page.handle(event)
  of 4: jobs_page.handle(event)
  of 5: input_page.handle(event)
  else: controls_page.handle(event)

proc updatePages(now: MonoTime): int =
  result = -1
  result.wakeWithin(widgets_page.update(now, page == 0))
  result.wakeWithin(charts_page.update(now, page == 1))
  result.wakeWithin(text_page.update(now, page == 2))
  result.wakeWithin(motion_page.update(now, page == 3))
  result.wakeWithin(jobs_page.update(now, page == 4))
  result.wakeWithin(input_page.update(now, page == 5))
  result.wakeWithin(controls_page.update(now, page == 6))

proc showcase(frame: var Frame) =
  # Header, a breathing row, the page, then one row of key hints.
  let areas = vertical([length(1), length(1), fill(), length(1)]).split(frame.area)
  var brand = initLine([initSpan(" ◆ ", accent().bold()), initSpan("Canopy", initStyle().bold()),
    initSpan(" showcase  ", muted())])
  let dim = muted()

  let tabsWidth = pillsWidth(pageNames, numbered = true)

  # Live stats sit on the right. When the row gets narrow, the least useful ones go first;
  # the theme and motion state stay longest because they answer the t and m keys.
  var room = areas[0].width - brand.width - tabsWidth - 2
  let candidates = [($cellUpdates, "cells", 1), ($frames, "frames", 3),
    ($screen.width & "×" & $screen.height, "", 2),
    (themeNames[themeIndex], if animator.reducedMotion: "· reduced motion" else: "", 0)]
  proc statsFor(dropRank: int): Line =
    var spans: seq[Span]
    for (value, label, rank) in candidates:
      if rank >= dropRank: continue
      if spans.len > 0: spans.add(initSpan(" · ", dim))
      spans.add(initSpan(value, accent()))
      if label.len > 0: spans.add(initSpan(" " & label, dim))
    spans.add(initSpan(" "))
    initLine(spans).rightAligned()
  if statsFor(1).width > room:
    # Keep the theme and motion state visible before the brand's subtitle.
    brand = initLine([initSpan(" ◆ ", accent().bold()), initSpan("Canopy ", initStyle().bold())])
    room = areas[0].width - brand.width - tabsWidth - 2
  var statsLine = initLine("")
  for dropRank in countdown(candidates.len, 1):
    let line = statsFor(dropRank)
    if line.width <= room:
      statsLine = line
      break
  let header = horizontal([length(brand.width), fill(), length(statsLine.width)]).split(areas[0])
  frame.renderWidget(brand, header[0])
  frame.renderWidget(statsLine, header[2])

  frame.renderPills(header[1], pageNames, page, tabHits, numbered = true)

  contentArea = areas[2]
  renderPage(frame, contentArea)
  if pageTransition != nil: pageTransition.apply(frame.buffer[], contentArea)

  let global = initLine(keyHints("Tab/1-7: page · t: theme · m: motion · q: quit") &
    @[initSpan(" ", dim)]).rightAligned()
  let footer = horizontal([fill(), length(global.width)]).split(areas[3])
  frame.renderWidget(initLine(@[initSpan(" ")] & keyHints(pageHelp())), footer[0])
  frame.renderWidget(global, footer[1])

proc showPage(index: int) =
  let next = (index + pageNames.len) mod pageNames.len
  if next == page: return
  page = next
  if lastFrame.content.len == 0 or contentArea.width == 0: return
  if pageTransition != nil: pageTransition.cancel()
  pageTransition = initTransition(lastFrame, contentArea, initDuration(milliseconds = 220),
    TransitionEffect.Wipe, TransitionDirection.Left)
  animator.play(pageTransition)

proc handle(event: input.Event): bool =
  ## Returns false when the app should exit.
  result = true
  input_page.record(event)
  # The controls page sees events first: its fields and dialogs own q, Escape and digits.
  if page == 6 and handlePage(event): return
  if event.isPress and (event.key.text == "q" or event.key.code == KeyCode.Escape or
      (event.key.text == "c" and KeyModifier.Control in event.key.modifiers)):
    return false
  let click = event.leftClick
  if click.isSome:
    for i, hit in tabHits:
      if hit.contains(click.get): showPage(i); return
  if (page != 6 and handlePage(event)) or not event.isPress: return
  case event.key.code
  of KeyCode.Tab:
    showPage(page + (if KeyModifier.Shift in event.key.modifiers: -1 else: 1))
  of KeyCode.BackTab: showPage(page - 1)
  else:
    case event.key.text
    of "1", "2", "3", "4", "5", "6", "7": showPage(ord(event.key.text[0]) - ord('1'))
    of "t": themeIndex = (themeIndex + 1) mod themeNames.len
    of "m": animator.reducedMotion = not animator.reducedMotion
    else: discard

proc run() =
  var capabilities = defaultInputCapabilities()
  capabilities.mouseCapture = true
  # RecordingBackend is the custom-backend demo: it wraps the ANSI backend and counts cells.
  withTerminal(terminal, initRecordingBackend(initAnsiBackend())):
    withInput(events, initInput(capabilities = capabilities, rawMode = false)):
      discard animator.advance(getMonoTime())
      while true:
        var timeout = updatePages(getMonoTime())
        discard animator.advance(getMonoTime())
        screen = terminal.size()
        terminal.backend.cellUpdates = 0
        lastFrame = terminal.draw(showcase).buffer
        cellUpdates = terminal.backend.cellUpdates
        inc frames
        let wake = animator.nextWake(getMonoTime())
        if wake.isSome:
          timeout.wakeWithin(int((wake.get.inNanoseconds + 999_999) div 1_000_000))
        let event = events.poll(timeout)
        if events.eof: break
        if event.isSome:
          discard animator.advance(getMonoTime())
          if not handle(event.get): break

if "--round" in commandLineParams(): roundPills = true
if "--square" in commandLineParams(): roundPills = false
if "--inline" in commandLineParams(): runInlineDemo()
else: run()
