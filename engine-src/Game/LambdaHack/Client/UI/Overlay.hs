{-# LANGUAGE RankNTypes #-}
-- | Screen overlays.
module Game.LambdaHack.Client.UI.Overlay
  ( -- * AttrString
    AttrString, blankAttrString, textToAS, textFgToAS, stringToAS, (<+:>)
    -- * AttrLine
  , AttrLine, attrLine, emptyAttrLine, attrStringToAL, paragraph1OfAS, linesAttr
  , textToAL, textFgToAL, stringToAL, splitAttrString, indentSplitAttrString
    -- * Overlay
  , Overlay, offsetOverlay, offsetOverlayX, updateLine
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , splitAttrPhrase
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.Text as T

import           Game.LambdaHack.Client.UI.Key (PointUI (..))
import qualified Game.LambdaHack.Definition.Color as Color

-- * AttrString

-- | String of colourful text. End of line characters permitted.
type AttrString = [Color.AttrCharW32]

blankAttrString :: Int -> AttrString
blankAttrString w = replicate w Color.spaceAttrW32

textToAS :: Text -> AttrString
textToAS !t =
  let f c l = let !ac = Color.attrChar1ToW32 c
              in ac : l
  in T.foldr f [] t

textFgToAS :: Color.Color -> Text -> AttrString
textFgToAS !fg !t =
  let f ' ' l = Color.spaceAttrW32 : l
                  -- for speed and simplicity (testing if char is a space)
                  -- we always keep the space @White@
      f c l = let !ac = Color.attrChar2ToW32 fg c
              in ac : l
  in T.foldr f [] t

stringToAS :: String -> AttrString
stringToAS = map Color.attrChar1ToW32

infixr 6 <+:>  -- matches Monoid.<>
(<+:>) :: AttrString -> AttrString -> AttrString
(<+:>) [] l2 = l2
(<+:>) l1 [] = l1
(<+:>) l1 l2 = l1 ++ [Color.spaceAttrW32] ++ l2

-- We consider only these, because they are short and form a closed category.
nonbreakableRev :: [AttrString]
nonbreakableRev = map stringToAS ["eht", "a", "na", "ehT", "A", "nA"]

breakAtSpace :: AttrString -> (AttrString, AttrString)
breakAtSpace lRev =
  let (pre, post) = break (== Color.spaceAttrW32) lRev
  in case post of
    c : rest | c == Color.spaceAttrW32 ->
      if any (`isPrefixOf` rest) nonbreakableRev
      then let (pre2, post2) = breakAtSpace rest
           in (pre ++ c : pre2, post2)
      else (pre, post)
    _ -> (pre, post)  -- no space found, give up

-- * AttrLine

-- | Line of colourful text. End of line characters forbidden.
newtype AttrLine = AttrLine {attrLine :: [Color.AttrCharW32]}
  deriving (Show, Eq)

emptyAttrLine :: AttrLine
emptyAttrLine = AttrLine []

attrStringToAL :: AttrString -> AttrLine
attrStringToAL s = assert (all (\ac -> Color.charFromW32 ac /= '\n') s)
                   $ AttrLine s

paragraph1OfAS :: AttrString -> AttrLine
paragraph1OfAS s = case linesAttr s of
  [] -> emptyAttrLine
  l : _ -> l

textToAL :: Text -> AttrLine
textToAL !t =
  let f '\n' _ = error $ "illegal end of line in: " ++ T.unpack t
      f c l = let !ac = Color.attrChar1ToW32 c
              in ac : l
  in AttrLine $ T.foldr f [] t

textFgToAL :: Color.Color -> Text -> AttrLine
textFgToAL !fg !t =
  let f '\n' _ = error $ "illegal end of line in: " ++ T.unpack t
      f ' ' l = Color.spaceAttrW32 : l
                  -- for speed and simplicity (testing if char is a space)
                  -- we always keep the space @White@
      f c l = let !ac = Color.attrChar2ToW32 fg c
              in ac : l
  in AttrLine $ T.foldr f [] t

stringToAL :: String -> AttrLine
stringToAL s = assert (all (/= '\n') s)
               $ AttrLine $ map Color.attrChar1ToW32 s

linesAttr :: AttrString -> [AttrLine]
linesAttr l | null l = []
            | otherwise = AttrLine h : if null t then [] else linesAttr (tail t)
 where (h, t) = span (\ac -> Color.charFromW32 ac /= '\n') l

-- | Split a string into lines. Avoids ending the line with
-- a character other than space. Space characters are removed
-- from the start, but never from the end of lines. Newlines are respected.
--
-- Note that we only split wrt @White@ space, nothing else,
-- and the width, in the first argument, is calculated in characters,
-- not in UI (mono font) coordinates, so that taking and dropping characters
-- is performed correctly.
splitAttrString :: Int -> AttrString -> [AttrLine]
splitAttrString w l =
  concatMap (splitAttrPhrase w
             . AttrLine . dropWhile (== Color.spaceAttrW32) . attrLine)
  $ linesAttr l

indentSplitAttrString :: Int -> AttrString -> [AttrLine]
indentSplitAttrString w l =
  -- First line could be split at @w@, not @w - 1@, but it's good enough.
  let ts = splitAttrString (w - 1) l
  in case ts of
    [] -> []
    hd : tl -> hd : map (AttrLine . ([Color.spaceAttrW32] ++) . attrLine) tl

-- We pass empty line along for the case of appended buttons, which need
-- either space or new lines before them.
splitAttrPhrase :: Int -> AttrLine -> [AttrLine]
splitAttrPhrase w (AttrLine xs)
  | w >= length xs = [AttrLine xs]  -- no problem, everything fits
  | otherwise =
      let (pre, postRaw) = splitAt w xs
          preRev = reverse pre
          ((ppre, ppost), post) = case postRaw of
            c : rest | c == Color.spaceAttrW32
                       && not (any (`isPrefixOf` preRev) nonbreakableRev) ->
              (([], preRev), rest)
            _ -> (breakAtSpace preRev, postRaw)
          testPost = dropWhileEnd (== Color.spaceAttrW32) ppost
      in if null testPost
         then AttrLine pre :
              splitAttrPhrase w (AttrLine post)
         else AttrLine (reverse ppost)
              : splitAttrPhrase w (AttrLine $ reverse ppre ++ post)

-- * Overlay

-- | A series of screen lines with points at which they should ber overlayed
-- over the base frame or a blank screen, depending on context.
-- The point is represented as in integer that is an index into the
-- frame character array.
-- The lines either fit the width of the screen or are intended
-- for truncation when displayed. The positions of lines may fall outside
-- the length of the screen, too, unlike in @SingleFrame@. Then they are
-- simply not shown.
type Overlay = [(PointUI, AttrLine)]

offsetOverlay :: [AttrLine] -> Overlay
offsetOverlay l = map (\(y, al) -> (PointUI 0 y, al)) $ zip [0..] l

offsetOverlayX :: [(Int, AttrLine)] -> Overlay
offsetOverlayX l =
  map (\(y, (x, al)) -> (PointUI x y, al)) $ zip [0..] l

-- @f@ should not enlarge the line beyond screen width nor introduce linebreaks.
updateLine :: Int -> (Int -> AttrString -> AttrString) -> Overlay -> Overlay
updateLine y f ov =
  let upd (p@(PointUI px py), AttrLine l) =
        if py == y then (p, AttrLine $ f px l) else (p, AttrLine l)
  in map upd ov
