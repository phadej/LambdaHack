-- | Slideshows.
module Game.LambdaHack.Client.UI.Slideshow
  ( DisplayFont, isSquareFont
  , FontOverlayMap, FontSetup(..), multiFontSetup, singleFontSetup, textSize
  , ButtonWidth(..), KYX, OKX, Slideshow(slideshow)
  , emptySlideshow, unsnoc, toSlideshow, maxYofOverlay, menuToSlideshow
  , wrapOKX, splitOverlay, splitOKX, highSlideshow
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , moreMsg, endMsg, keysOKX, showTable, showNearbyScores
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM
import           Data.Time.LocalTime

import           Game.LambdaHack.Client.UI.ItemSlot
import           Game.LambdaHack.Client.UI.Key (PointUI (..))
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.Overlay
import qualified Game.LambdaHack.Common.HighScore as HighScore
import qualified Game.LambdaHack.Definition.Color as Color

data DisplayFont = SquareFont | MonoFont | PropFont
  deriving (Show, Eq, Enum)

isSquareFont :: DisplayFont -> Bool
isSquareFont SquareFont = True
isSquareFont _ = False

type FontOverlayMap = EM.EnumMap DisplayFont Overlay

data FontSetup = FontSetup
  { multiFont  :: Bool
  , squareFont :: DisplayFont
  , monoFont   :: DisplayFont
  , propFont   :: DisplayFont
  }

multiFontSetup :: FontSetup
multiFontSetup = FontSetup True SquareFont MonoFont PropFont

singleFontSetup :: FontSetup
singleFontSetup = FontSetup False SquareFont SquareFont SquareFont

textSize :: DisplayFont -> [a] -> Int
textSize SquareFont l = 2 * length l
textSize MonoFont l = length l
textSize PropFont _ = error "size of proportional font texts is not defined"

-- TODO: probably best merge the PointUI into that and represent
-- the position as characters, too, translating to UI positions as needed.
-- The problem is that then I need to do a lot of reverse translation
-- when creating buttons.
-- | Width of on-screen button text, expressed in characters,
-- and so UI (mono font) width is deduced from the used font.
data ButtonWidth = ButtonWidth
  { buttonFont  :: DisplayFont
  , buttonWidth :: Int }
  deriving (Show, Eq)

-- | A key or an item slot label at a given position on the screen.
type KYX = (Either [K.KM] SlotChar, (PointUI, ButtonWidth))

-- | An Overlay of text with an associated list of keys or slots
-- that activated when the specified screen position is pointed at.
-- The list should be sorted wrt rows and then columns.
type OKX = (FontOverlayMap, [KYX])

-- | A list of active screenfulls to be shown one after another.
-- Each screenful has an independent numbering of rows and columns.
newtype Slideshow = Slideshow {slideshow :: [OKX]}
  deriving (Show, Eq)

emptySlideshow :: Slideshow
emptySlideshow = Slideshow []

unsnoc :: Slideshow -> Maybe (Slideshow, OKX)
unsnoc Slideshow{slideshow} =
  case reverse slideshow of
    [] -> Nothing
    okx : rest -> Just (Slideshow $ reverse rest, okx)

toSlideshow :: FontSetup -> [OKX] -> Slideshow
toSlideshow FontSetup{..} okxs = Slideshow $ addFooters False okxsNotNull
 where
  okxFilter (ov, kyxs) =
    (ov, filter (either (not . null) (const True) . fst) kyxs)
  okxsNotNull = map okxFilter okxs
  pofOv :: Overlay -> PointUI
  pofOv [] = PointUI 0 0
  pofOv l = let pyAfterLast = 1 + maxYofOverlay l  -- append after last line
            in PointUI 0 pyAfterLast
  atEnd = flip (++)
  appendToFontOverlayMap :: FontOverlayMap -> AttrLine
                         -> (FontOverlayMap, PointUI, DisplayFont)
  appendToFontOverlayMap ovs al =
    let maxYminXofOverlay ov = let ymxOfOverlay (PointUI x y, _) = (- y, x)
                               in minimum $ (0, 0) : map ymxOfOverlay ov
        assocsYX = sortOn snd $ EM.assocs $ EM.map maxYminXofOverlay ovs
        (fontMax, unique) = case assocsYX of
          [] -> (monoFont, False)
          (font, (y, _x)) : rest -> (font, all (\(_, (y2, _)) -> y /= y2) rest)
        insertAl ovF =
          let p = pofOv ovF
              displayFont = case fontMax of
                SquareFont | unique -> SquareFont
                _ -> monoFont
          in (EM.insertWith atEnd displayFont [(p, al)] ovs, p, displayFont)
    in case EM.lookup fontMax ovs of
      Just ovF -> insertAl ovF
      Nothing -> insertAl []
  addFooters :: Bool -> [OKX] -> [OKX]
  addFooters _ [] = error $ "" `showFailure` okxsNotNull
  addFooters _ [(als, [])] =
    let (ovs, p, font) = appendToFontOverlayMap als (stringToAL endMsg)
    in [(ovs, [(Left [K.safeSpaceKM], (p, ButtonWidth font 15))])]
  addFooters False [(als, kxs)] = [(als, kxs)]
  addFooters True [(als, kxs)] =
    let (ovs, p, font) = appendToFontOverlayMap als (stringToAL endMsg)
    in [(ovs, kxs ++ [(Left [K.safeSpaceKM], (p, ButtonWidth font 15))])]
  addFooters _ ((als, kxs) : rest) =
    let (ovs, p, font) = appendToFontOverlayMap als (stringToAL moreMsg)
    in (ovs, kxs ++ [(Left [K.safeSpaceKM], (p, ButtonWidth font 8))])
       : addFooters True rest

moreMsg :: String
moreMsg = "--more--  "

endMsg :: String
endMsg = "--back to top--  "

maxYofOverlay :: Overlay -> Int
maxYofOverlay ov = let yOfOverlay (PointUI _ y, _) = y
                   in maximum $ 0 : map yOfOverlay ov

menuToSlideshow :: OKX -> Slideshow
menuToSlideshow (als, kxs) =
  assert (not (EM.null als || null kxs)) $ Slideshow [(als, kxs)]

wrapOKX :: DisplayFont -> Int -> Int -> Int -> [(K.KM, String)]
        -> (Overlay, [KYX])
wrapOKX _ _ _ _ [] = ([], [])
wrapOKX displayFont ystart xstart width ks =
  let overlayLineFromStrings :: Int -> Int -> [String] -> (PointUI, AttrLine)
      overlayLineFromStrings xlineStart y strings =
        let p = PointUI xlineStart y
        in (p, stringToAL $ intercalate " " (reverse strings))
      f :: ((Int, Int), (Int, [String], Overlay, [KYX])) -> (K.KM, String)
        -> ((Int, Int), (Int, [String], Overlay, [KYX]))
      f ((y, x), (xlineStart, kL, kV, kX)) (key, s) =
        let len = textSize displayFont s
            len1 = len + textSize displayFont " "
        in if x + len >= width
           then let iov = overlayLineFromStrings xlineStart y kL
                in f ((y + 1, 0), (0, [], iov : kV, kX)) (key, s)
           else ( (y, x + len1)
                , ( xlineStart
                  , s : kL
                  , kV
                  , (Left [key], ( PointUI x y
                                 , ButtonWidth displayFont (length s) ))
                    : kX ) )
      ((ystop, _), (xlineStop, kL1, kV1, kX1)) =
        foldl' f ((ystart, xstart), (xstart, [], [], [])) ks
      iov1 = overlayLineFromStrings xlineStop ystop kL1
  in (reverse $ iov1 : kV1, reverse kX1)

keysOKX :: DisplayFont -> Int -> Int -> Int -> [K.KM] -> (Overlay, [KYX])
keysOKX displayFont ystart xstart width keys =
  let wrapB :: String -> String
      wrapB s = "[" ++ s ++ "]"
      ks = map (\key -> (key, wrapB $ K.showKM key)) keys
  in wrapOKX displayFont ystart xstart width ks

-- The font argument is for the report and keys overlay. Others already have
-- assigned fonts.
splitOverlay :: FontSetup -> Int -> Int -> Report -> [K.KM] -> OKX
             -> Slideshow
splitOverlay fontSetup width height report keys (ls0, kxs0) =
  toSlideshow fontSetup $ splitOKX fontSetup False width height
                                   (renderReport report) keys (ls0, kxs0)

-- Note that we only split wrt @White@ space, nothing else.
splitOKX :: FontSetup -> Bool -> Int -> Int -> AttrString -> [K.KM] -> OKX
         -> [OKX]
splitOKX FontSetup{..} msgLong width height reportAS keys (ls0, kxs0) =
  assert (height > 2) $
  let reportParagraphs = linesAttr reportAS
      -- TODO: until SDL support for measuring prop font text is released,
      -- we have to use MonoFont for the paragraph that ends with buttons.
      (repPrep, repMono) =
        if null keys
        then (reportParagraphs, emptyAttrLine)
        else case reverse reportParagraphs of
          [] -> ([], emptyAttrLine)
          l : rest ->
            (reverse rest, attrStringToAL $ attrLine l ++ [Color.spaceAttrW32])
      msgWidth = if msgLong && not (isSquareFont propFont)
                 then 2 * width
                 else width
      repPrep0 = offsetOverlay
                 $ concatMap (splitAttrString msgWidth . attrLine) repPrep
      repMono0 = map (\(PointUI x y, al) ->
                        (PointUI x (y + length repPrep0), al))
                 $ offsetOverlay
                 $ splitAttrString msgWidth $ attrLine repMono
      repWhole0 = offsetOverlay $ splitAttrString msgWidth reportAS
      repWhole1 = map (\(PointUI x y, al) -> (PointUI x (y + 1), al)) repWhole0
      lenOfRep = length repPrep0 + length repMono0
      startOfKeys = if null repMono0
                    then 0
                    else textSize monoFont (attrLine $ snd $ last repMono0)
      (lX0, keysX0) = keysOKX monoFont 0 0 width keys
      (lX1, keysX1) = keysOKX monoFont 1 0 width keys
      (lX, keysX) = keysOKX monoFont (lenOfRep - 1) startOfKeys
                            (2 * width) keys
      renumber dy (km, (PointUI x y, len)) = (km, (PointUI x (y + dy), len))
      renumberOv dy = map (\(PointUI x y, al) -> (PointUI x (y + dy), al))
      splitO :: Int -> (Overlay, Overlay, [KYX]) -> OKX -> [OKX]
      splitO yoffset (hdrPrep, hdrMono, rk) (ls, kxs) =
        let hdrOff | null hdrPrep && null hdrMono = 0
                   | otherwise = 1 + maxYofOverlay hdrMono
            keyRenumber = map $ renumber (hdrOff - yoffset)
            lineRenumber = EM.map $ renumberOv (hdrOff - yoffset)
            yoffsetNew = yoffset + height - hdrOff - 1
            ltOffset :: (PointUI, a) -> Bool
            ltOffset (PointUI _ y, _) = y < yoffsetNew
            (pre, post) = ( filter ltOffset <$> ls
                          , filter (not . ltOffset) <$> ls )
            prependHdr = EM.insertWith (++) propFont hdrPrep
                         . EM.insertWith (++) monoFont hdrMono
        in if all null $ EM.elems post  -- all fits on one screen
           then [(prependHdr $ lineRenumber pre, rk ++ keyRenumber kxs)]
           else let (preX, postX) = span (\(_, pa) -> ltOffset pa) kxs
                in (prependHdr $ lineRenumber pre, rk ++ keyRenumber preX)
                   : splitO yoffsetNew (hdrPrep, hdrMono, rk) (post, postX)
      hdrShortened = ( [(PointUI 0 0, paragraph1OfAS reportAS)]
                         -- shortened for the main slides; in full beforehand
                     , take 3 lX1  -- 3 lines ought to be enough for everyone
                     , keysX1 )
      ((lsInit, kxsInit), (headerProp, headerMono, rkxs)) =
        -- Check whether most space taken by report and keys.
        if | (lenOfRep + length lX) * 3 < 2 * height ->  -- display normally
             ((EM.empty, []), (repPrep0, lX ++ repMono0, keysX))
           | length reportAS <= 2 * width ->  -- very crude check, but OK
             ( (EM.empty, [])  -- already shown in full in shortened header
             , hdrShortened )
           | otherwise -> case lX0 of
               [] ->
                 ( (EM.singleton propFont repWhole0, [])
                     -- showing in full in the init slide
                 , hdrShortened )
               lX0first : _ ->
                 ( ( EM.insertWith (++) propFont repWhole1
                     $ EM.singleton monoFont [lX0first]
                   , filter (\(_, (PointUI _ y, _)) -> y == 0) keysX0 )
                 , hdrShortened )
      initSlides = if EM.null lsInit
                   then assert (null kxsInit) []
                   else splitO 0 ([], [], []) (lsInit, kxsInit)
      -- If @ls0@ is not empty, we still want to display the report,
      -- one way or another.
      mainSlides = if EM.null ls0 && (not $ EM.null lsInit)
                   then assert (null kxs0) []
                   else splitO 0 (headerProp, headerMono, rkxs) (ls0, kxs0)
  in initSlides ++ mainSlides

-- | Generate a slideshow with the current and previous scores.
highSlideshow :: FontSetup
              -> Int        -- ^ width of the display area
              -> Int        -- ^ height of the display area
              -> HighScore.ScoreTable -- ^ current score table
              -> Int        -- ^ position of the current score in the table
              -> Text       -- ^ the name of the game mode
              -> TimeZone   -- ^ the timezone where the game is run
              -> Slideshow
highSlideshow fontSetup@FontSetup{monoFont} width height table pos
              gameModeName tz =
  let entries = (height - 3) `div` 3
      msg = HighScore.showAward entries table pos gameModeName
      tts = map offsetOverlay $ showNearbyScores tz pos table entries
      al = textToAS msg
      splitScreen ts =
        splitOKX fontSetup False width height al [K.spaceKM, K.escKM]
                 (EM.singleton monoFont ts, [])
  in toSlideshow fontSetup $ concat $ map splitScreen tts

-- | Show a screenful of the high scores table.
-- Parameter @entries@ is the number of (3-line) scores to be shown.
showTable :: TimeZone -> Int -> HighScore.ScoreTable -> Int -> Int
          -> [AttrLine]
showTable tz pos table start entries =
  let zipped    = zip [1..] $ HighScore.unTable table
      screenful = take entries . drop (start - 1) $ zipped
      renderScore (pos1, score1) =
        map (if pos1 == pos then textFgToAL Color.BrWhite else textToAL)
        $ HighScore.showScore tz pos1 score1
  in emptyAttrLine : intercalate [emptyAttrLine] (map renderScore screenful)

-- | Produce a couple of renderings of the high scores table.
showNearbyScores :: TimeZone -> Int -> HighScore.ScoreTable -> Int
                 -> [[AttrLine]]
showNearbyScores tz pos h entries =
  if pos <= entries
  then [showTable tz pos h 1 entries]
  else [showTable tz pos h 1 entries,
        showTable tz pos h (max (entries + 1) (pos - entries `div` 2)) entries]
