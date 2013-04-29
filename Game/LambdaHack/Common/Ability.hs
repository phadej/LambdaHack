-- | AI strategy abilities.
module Game.LambdaHack.Common.Ability
  ( Ability(..)
  ) where

-- | All possible AI actor abilities. AI chooses among these when considering
-- the next action to perform. The ability descriptions refer to the target
-- that any actor picks each turn, depending on the actor's characteristics
-- and his environment.
data Ability =
    Track   -- ^ move along a set path, if any, meleeing any opponents
  | Heal    -- ^ heal if almost dead
  | Flee    -- ^ flee if almost dead
  | Melee   -- ^ melee target
  | Pickup  -- ^ gather items, if no foes visible
  | Ranged  -- ^ attack the visible target opponent at range, some of the time
  | Tools   -- ^ use items, if target opponent visible, some of the time
  | Chase   -- ^ chase the target, ignoring any actors on the way
  | Wander  -- ^ wander around, meleeing any opponents on the way
  deriving (Show, Eq, Ord, Enum, Bounded)

  -- A note for when we let AI change levels:
  -- A faction that spawns cannot switch levels (nor move between levels).
  -- Otherwise it would constantly go to a distant level, spawn actors there
  -- and swarm any opponent arriving on the level.
