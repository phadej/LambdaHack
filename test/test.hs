import TieKnot

main :: IO ()
main =
  tieKnot $ tail $ words "dist/build/LambdaHack/LambdaHack --dbgMsgSer --savePrefix test --newGame 2 --noAnim --maxFps 100000 --frontendNull --benchmark --stopAfter 1 --automateAll --keepAutomated --gameMode campaign --setDungeonRng 42 --setMainRng 42"
  -- tieKnot $ tail $ words "dist/build/LambdaHack/LambdaHack --dbgMsgSer --savePrefix test --newGame 2 --noAnim --maxFps 100000 --frontendNull --benchmark --stopAfter 6 --automateAll --keepAutomated --gameMode battle --setDungeonRng 42 --setMainRng 42"
