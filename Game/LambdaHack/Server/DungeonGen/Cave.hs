-- | Generation of caves (not yet inhabited dungeon levels) from cave kinds.
module Game.LambdaHack.Server.DungeonGen.Cave
  ( Cave(..), buildCave
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import Data.Key (mapWithKeyM)

import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.PlaceKind
import Game.LambdaHack.Content.TileKind (TileKind)
import Game.LambdaHack.Server.DungeonGen.Area
import Game.LambdaHack.Server.DungeonGen.AreaRnd
import Game.LambdaHack.Server.DungeonGen.Place

-- | The type of caves (not yet inhabited dungeon levels).
data Cave = Cave
  { dkind   :: !(Kind.Id CaveKind)  -- ^ the kind of the cave
  , dmap    :: !TileMapEM           -- ^ tile kinds in the cave
  , dplaces :: ![Place]             -- ^ places generated in the cave
  , dnight  :: !Bool                -- ^ whether the cave is dark
  }
  deriving Show

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a grid, e.g, 3 by 3,
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random position
    and with a random size, but larger than The minimum size,
    e.g, 2 by 2 floor tiles.

  * Rooms that are on horizontally or vertically adjacent grid cells
    may be connected by a corridor. Corridors consist of 3 segments of straight
    lines (either "horizontal, vertical, horizontal" or "vertical, horizontal,
    vertical"). They end in openings in the walls of the room they connect.
    It is possible that one or two of the 3 segments have length 0, such that
    the resulting corridor is L-shaped or even a single straight line.

  * Corridors are generated randomly in such a way that at least every room
    on the grid is connected, and a few more might be. It is not sufficient
    to always connect all adjacent rooms.
-}
-- TODO: fix identifier naming and split, after the code grows some more
-- | Cave generation by an algorithm inspired by the original Rogue,
buildCave :: Kind.COps         -- ^ content definitions
          -> AbsDepth          -- ^ depth of the level to generate
          -> AbsDepth          -- ^ absolute depth
          -> Kind.Id CaveKind  -- ^ cave kind to use for generation
          -> [(Point, GroupName PlaceKind)]  -- ^ position of stairs, etc.
          -> Rnd Cave
buildCave cops@Kind.COps{ cotile=cotile@Kind.Ops{opick}
                        , cocave=Kind.Ops{okind}
                        , coTileSpeedup }
          ldepth totalDepth dkind fixedCenters = do
  let kc@CaveKind{..} = okind dkind
  lgrid' <- castDiceXY ldepth totalDepth cgrid
  -- Make sure that in caves not filled with rock, there is a passage
  -- across the cave, even if a single room blocks most of the cave.
  -- Also, ensure fancy outer fences are not obstructed by room walls.
  let fullArea = fromMaybe (assert `failure` kc)
                 $ toArea (0, 0, cxsize - 1, cysize - 1)
      subFullArea = fromMaybe (assert `failure` kc)
                    $ toArea (1, 1, cxsize - 2, cysize - 2)
      fractionOfPlaces (gx, gy) r = round $ r * fromIntegral (gx * gy)
  darkCorTile <- fromMaybe (assert `failure` cdarkCorTile)
                 <$> opick cdarkCorTile (const True)
  litCorTile <- fromMaybe (assert `failure` clitCorTile)
                <$> opick clitCorTile (const True)
  dnight <- chanceDice ldepth totalDepth cnightChance
  let createPlaces lgr'@(gx', gy') = do
        let area | gx' * gy' == 1
                   || couterFenceTile /= "basic outer fence" = subFullArea
                 | otherwise = fullArea
            (lgr@(gx, gy), gs) =
              grid (map fst fixedCenters
                    ++ [Point 3 3, Point (cxsize - 4) (cysize - 4)]) lgr' area
        minPlaceSize <- castDiceXY ldepth totalDepth cminPlaceSize
        maxPlaceSize <- castDiceXY ldepth totalDepth cmaxPlaceSize
        voidPlaces <-
          if gx * gy > 1 then do
            let gridArea = fromMaybe (assert `failure` lgr)
                           $ toArea (0, 0, gx - 1, gy - 1)
                voidNum = fractionOfPlaces lgr cmaxVoid
            replicateM voidNum $ xyInArea gridArea  -- repetitions are OK
          else return []
        let decidePlace :: (TileMapEM, [Place], EM.EnumMap Point (Area, Area))
                        -> (Point, Area)
                        -> Rnd ( TileMapEM, [Place]
                               , EM.EnumMap Point (Area, Area) )
            decidePlace (!m, !pls, !qls) (!i, !ar) = do
              -- Reserved for corridors and the global fence.
              let innerArea = fromMaybe (assert `failure` (i, ar)) $ shrink ar
              case find (\(p, _) -> p `inside` fromArea ar) fixedCenters of
                Nothing -> do
                  if i `elem` voidPlaces
                  then do
                    r <- mkVoidRoom innerArea
                    return (m, pls, EM.insert i (r, r) qls)
                  else do
                    r <- mkRoom minPlaceSize maxPlaceSize innerArea
                    (tmap, place) <-
                      buildPlace cops kc dnight darkCorTile litCorTile
                                 ldepth totalDepth r Nothing
                    return ( EM.union tmap m
                           , place : pls
                           , EM.insert i (borderPlace cops place) qls )
                Just (p, placeGroup) -> do
                    r <- mkFixed minPlaceSize maxPlaceSize innerArea p
                    (tmap, place) <-
                      buildPlace cops kc dnight darkCorTile litCorTile
                                 ldepth totalDepth r (Just placeGroup)
                    return ( EM.union tmap m
                           , place : pls
                           , EM.insert i (borderPlace cops place) qls )
        places <- foldlM' decidePlace (EM.empty, [], EM.empty) gs
        return (lgr, places)
  (lgrid, (lplaces, dplaces, qplaces)) <- createPlaces lgrid'
  let lcorridorsFun lgr@(gx, gy) = do
        addedConnects <-
          if gx * gy > 1 then do
            let cauxNum = fractionOfPlaces lgr cauxConnects
            replicateM cauxNum (randomConnection lgr)
          else return []
        connects <- connectGrid lgr
        let allConnects = connects `union` addedConnects  -- duplicates removed
            connectPos :: (Point, Point) -> Rnd Corridor
            connectPos (p0, p1) =
              connectPlaces (qplaces EM.! p0) (qplaces EM.! p1)
        cs <- mapM connectPos allConnects
        let pickedCorTile = if dnight then darkCorTile else litCorTile
        return $! EM.unions (map (digCorridors pickedCorTile) cs)
  lcorridors <- lcorridorsFun lgrid
  let doorMapFun lpl lcor = do
        -- The hacks below are instead of unionWithKeyM, which is costly.
        let mergeCor _ pl cor = if Tile.isWalkable coTileSpeedup pl
                                then Nothing  -- tile already open
                                else Just (Tile.hideAs cotile pl, cor)
            intersectionWithKeyMaybe combine =
              EM.mergeWithKey combine (const EM.empty) (const EM.empty)
            interCor = intersectionWithKeyMaybe mergeCor lpl lcor  -- fast
        mapWithKeyM (pickOpening cops kc lplaces litCorTile)
                    interCor  -- very small
  doorMap <- doorMapFun lplaces lcorridors
  fence <- buildFenceRnd cops couterFenceTile subFullArea
  let dmap = EM.unions [doorMap, lplaces, lcorridors, fence]  -- order matters
  return $! Cave {dkind, dmap, dplaces, dnight}

borderPlace :: Kind.COps -> Place -> (Area, Area)
borderPlace Kind.COps{coplace=Kind.Ops{okind}} Place{..} =
  case pfence (okind qkind) of
    FWall -> (qarea, qarea)
    FFloor  -> (qarea, expand qarea)
    FGround -> (qarea, expand qarea)
    FNone -> case shrink qarea of
      Nothing -> (qarea, qarea)
      Just sr -> (sr, qarea)

pickOpening :: Kind.COps -> CaveKind -> TileMapEM -> Kind.Id TileKind
            -> Point -> (Kind.Id TileKind, Kind.Id TileKind)
            -> Rnd (Kind.Id TileKind)
pickOpening Kind.COps{cotile, coTileSpeedup}
            CaveKind{cxsize, cysize, cdoorChance, copenChance}
            lplaces litCorTile
            pos (hidden, cor) = do
  let nicerCorridor =
        if Tile.isLit coTileSpeedup cor then cor
        else -- If any cardinally adjacent room tile lit, make the opening lit.
             let roomTileLit p =
                   case EM.lookup p lplaces of
                     Nothing -> False
                     Just tile -> Tile.isLit coTileSpeedup tile
                 vic = vicinityCardinal cxsize cysize pos
             in if any roomTileLit vic then litCorTile else cor
  -- Openings have a certain chance to be doors and doors have a certain
  -- chance to be open.
  rd <- chance cdoorChance
  if rd then do
    doorClosedId <- Tile.revealAs cotile hidden
    -- Not all solid tiles can hide a door.
    if Tile.isDoor coTileSpeedup doorClosedId then do  -- door created
      ro <- chance copenChance
      if ro then Tile.openTo cotile doorClosedId
      else return $! doorClosedId
    else return $! nicerCorridor
  else return $! nicerCorridor

digCorridors :: Kind.Id TileKind -> Corridor -> TileMapEM
digCorridors tile (p1:p2:ps) =
  EM.union corPos (digCorridors tile (p2:ps))
 where
  cor  = fromTo p1 p2
  corPos = EM.fromList $ zip cor (repeat tile)
digCorridors _ _ = EM.empty
