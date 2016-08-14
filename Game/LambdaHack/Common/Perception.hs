{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
-- | Actors perceiving other actors and the dungeon level.
--
-- Visibility works according to KISS. Everything that player sees is real.
-- There are no unmarked hidden tiles and only solid tiles can be marked,
-- so there are no invisible walls and to pass through an illusory wall,
-- you have use a turn bumping into it first. Only tiles marked with Suspect
-- can turn out to be another tile. (So, if all tiles are marked with
-- Suspect, the player knows nothing for sure, but this should be avoided,
-- because searching becomes too time-consuming.)
-- Each actor sees adjacent tiles, even when blind, so adjacent tiles are
-- known, so the actor can decide accurately whether to pass thorugh
-- or alter, etc.
--
-- Items are always real and visible. Actors are real, but can be invisible.
-- Invisible actors in walls can't be hit, but are hinted at when altering
-- the tile, so the player can flee or block. Invisible actors in open
-- space can be hit.
module Game.LambdaHack.Common.Perception
  ( -- * Public perception
    PerVisible(..)
  , PerSmelled(..)
  , Perception(..)
  , PerLid
  , PerFid
  , totalVisible, totalSmelled
  , nullPer, addPer, diffPer
    -- * Perception cache
  , PerReachable(..)
  , CacheBeforeLucid(..)
  , PerActor
  , PerceptionCache(..)
  , PerCacheLid
  , PerCacheFid
    -- * Data used in FOV computation and cached to speed it up
  , FovClear, FovClearLid, FovLucid(..), FovLucidLid
  , FovLit (..), FovLitLid, FovShine(..), FovShineLid
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import GHC.Generics (Generic)

import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray

-- * Public perception

-- | Visible positions.
newtype PerVisible = PerVisible
    {pvisible :: ES.EnumSet Point}
  deriving (Show, Eq, Binary)

-- | Smelled positions.
newtype PerSmelled = PerSmelled
    {psmelled :: ES.EnumSet Point}
  deriving (Show, Eq, Binary)

-- | The type representing the perception of a faction on a level.
data Perception = Perception
  { psight :: !PerVisible
  , psmell :: !PerSmelled
  }
  deriving (Show, Eq, Generic)

instance Binary Perception

-- | Perception of a single faction, indexed by level identifier.
type PerLid = EM.EnumMap LevelId Perception

-- | Perception indexed by faction identifier.
-- This can't be added to @FactionDict@, because clients can't see it
-- for other factions.
type PerFid = EM.EnumMap FactionId PerLid

-- | The set of tiles visible by at least one hero.
totalVisible :: Perception -> ES.EnumSet Point
totalVisible = pvisible . psight

-- | The set of tiles smelt by at least one hero.
totalSmelled :: Perception -> ES.EnumSet Point
totalSmelled = psmelled . psmell

nullPer :: Perception -> Bool
nullPer per = ES.null (totalVisible per) && ES.null (totalSmelled per)

addPer :: Perception -> Perception -> Perception
addPer per1 per2 =
  Perception
    { psight = PerVisible
               $ totalVisible per1 `ES.union` totalVisible per2
    , psmell = PerSmelled
               $ totalSmelled per1 `ES.union` totalSmelled per2
    }

diffPer :: Perception -> Perception -> Perception
diffPer per1 per2 =
  Perception
    { psight = PerVisible
               $ totalVisible per1 ES.\\ totalVisible per2
    , psmell = PerSmelled
               $ totalSmelled per1 ES.\\ totalSmelled per2
    }

-- * Perception cache

-- | Visually reachable positions (light passes through them to the actor).
-- They need to be intersected with lucid positions to obtain visible positions.
newtype PerReachable = PerReachable
    {preachable :: ES.EnumSet Point}
  deriving (Show, Eq)

data CacheBeforeLucid = CacheBeforeLucid
  { creachable :: !PerReachable
  , cnocto     :: !PerVisible
  , csmell     :: !PerSmelled
  }
  deriving (Show, Eq)

type PerActor = EM.EnumMap ActorId CacheBeforeLucid

data PerceptionCache = PerceptionCache
  { ptotal   :: !CacheBeforeLucid
  , perActor :: !PerActor
  }
  deriving (Show, Eq)

-- | Server cache of perceptions of a single faction,
-- indexed by level identifier.
type PerCacheLid = EM.EnumMap LevelId PerceptionCache

-- | Server cache of perceptions, indexed by faction identifier.
type PerCacheFid = EM.EnumMap FactionId PerCacheLid

-- * Data used in FOV computation and cached to speed it up

-- | Map of level positions that currently hold item or actor with shine
-- to the max of radiuses of the shining lights. Radius restricted here
-- for the purpose of Fov to 255, but elsewhere not restricted
-- (though elsewhere probably unused).
--
-- Note: ActorAspect and FovShine shoudn't be in State,
-- because on client they need to be updated every time an item discovery
-- is made, unlike on the server, where it's much simpler and cheaper.
newtype FovShine = FovShine
    {fovShine :: EM.EnumMap Point Word8}
  deriving (Show, Eq)

type FovShineLid = EM.EnumMap LevelId FovShine

type FovClear = PointArray.Array Bool

type FovClearLid = EM.EnumMap LevelId FovClear

-- | Level positions with either ambient light or shining items or actors.
newtype FovLucid = FovLucid
    {fovLucid :: ES.EnumSet Point}
  deriving (Show, Eq)

type FovLucidLid = EM.EnumMap LevelId FovLucid

-- | Level positions with tiles that have ambient light.
newtype FovLit = FovLit
    {fovLit :: ES.EnumSet Point}
  deriving (Show, Eq)

type FovLitLid = EM.EnumMap LevelId FovLit
