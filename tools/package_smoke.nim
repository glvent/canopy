## Compile against an installed package with repository config disabled.
import canopy
import canopy/runtime/terminal/input
import canopy/ui/animation/index as animation
import canopy/ui/controls/index as controls
doAssert displayWidth("👩‍🔬界") == 4
doAssert colorFromU32(0x123456'u32) == rgbColor(18, 52, 86)
var parser = initInputParser()
parser.feed("q")
doAssert parser.nextEvent().get.key.text == "q"
let animator = initAnimator()
let tween = initTween(0, 10, initDuration(milliseconds = 100))
let now = getMonoTime()
animator.play(tween)
discard animator.advance(now)
discard animator.advance(now+initDuration(milliseconds = 50))
doAssert tween.value == 5
withTerminal(terminal, initTestBackend(20, 3)):
  let frame = terminal.draw(proc(frame: var Frame) =
    frame.renderWidget(initParagraph("Installed package").withBlock(borderedBlock()), frame.area))
  doAssert frame.buffer[0, 0].symbol == "┌"
var fm = initFocusManager()
var name = initTextInputState(controlId("name"))
fm.focus(name.id)
withTerminal(terminal, initTestBackend(20, 1)):
  discard terminal.drawInteractive(fm, frame):
    frame.renderControl(fm, initTextInput(), frame.area, name)
  discard name.handle(fm.route(input.Event(kind: input.EventKind.Paste, text: "Zoë 界")))
  discard terminal.drawInteractive(fm, frame):
    frame.renderControl(fm, initTextInput(), frame.area, name)
  doAssert terminal.backend.buffer[2, 0].symbol == "ë"
doAssert name.text == "Zoë 界"
echo "Installed package imports, animates, edits and renders successfully"
