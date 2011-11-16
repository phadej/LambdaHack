module Game.LambdaHack.FOV.Shadow (scan, Interval) where

import Data.Ratio
import qualified Data.List as L

import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.FOV.Common
import Game.LambdaHack.Loc

-- Recursive Shadow Casting.

-- | A restrictive variant of Recursive Shadow Casting FOV with infinite range.
-- It's not designed for dungeons with diagonal walls, so they block visibility,
-- though they don't block movement. Such cases appear in the game only
-- when two corridors touch diagonally by accident and on the random pillars
-- levels.

{-
Field Of View
-------------

The algorithm used is a variant of Shadow Casting. We first compute
fields that are reachable (have unobstructed line of sight) from the hero's
position. Later, in Perception.hs,  from this information we compute
the fields that are visible (not hidden in darkness, etc.).

As input to the algorithm, we require information about fields that
block light. As output, we get information on the reachability of all fields.
We assume that the hero is located at position (0, 0)
and we only consider fields (line, row) where line >= 0 and 0 <= row <= line.
This is just about one eighth of the whole hero's surroundings,
but the other parts can be computed in the same fashion by mirroring
or rotating the given algorithm accordingly.

      fov (blocks, maxline) =
         shadow := \empty_set
         reachable (0, 0) := True
         for l \in [ 1 .. maxline ] do
            for r \in [ 0 .. l ] do
              reachable (l, r) := ( \exists a. a \in interval (l, r) \and
                                    a \not_in shadow)
              if blocks (l, r) then
                 shadow := shadow \union interval (l, r)
              end if
            end for
         end for
         return reachable

      interval (l, r) = return [ angle (l + 0.5, r - 0.5),
                                 angle (l - 0.5, r + 0.5) ]
      angle (l, r) = return atan (r / l)

The algorithm traverses the fields line by line, row by row.
At every moment, we keep in shadow the intervals which are in shadow,
measured by their angle. A square is reachable when any point
in it is not in shadow --- the algorithm is permissive in this respect.
We could also require that a certain fraction of the field is reachable,
or a specific point. Our choice has certain consequences. For instance,
a single blocking field throws a shadow, but the fields immediately behind
the blocking field are still visible.

We can compute the interval of angles corresponding to one square field
by computing the angle of the line passing the upper left corner
and the angle of the line passing the lower right corner.
This is what interval and angle do. If a field is blocking, the interval
for the square is added to the shadow set.
-}

type Interval = (Rational, Rational)

-- | The current state of a scan is kept in a variable of Maybe Rational.
-- If Just something, we're in a visible interval. If Nothing, we're in
-- a shadowed interval.
scan :: ((Distance, Progress) -> Loc) -> ((Progress, Distance) -> Bool)
     -> Distance -> Interval -> [Loc] -> [Loc]
scan tr isClear d (s0, e) !acc1 =
    let ps = downBias (s0 * fromIntegral d)  -- minimal progress to check
        pe = upBias (e * fromIntegral d)     -- maximal progress to check
        st = if isClear (ps, d)
             then Just s0  -- start in light
             else Nothing  -- start in shadow
        consLoc acc2 p = let !loc = tr (p, d) in loc : acc2
        acc = L.foldl' consLoc acc1 [ps..pe]
    in assert (d >= 0 && e >= 0 && s0 >= 0 && pe >= ps && ps >= 0
               `blame` (d,s0,e,ps,pe)) $
       mscan st ps pe acc
  where
    mscan :: Maybe Rational -> Progress -> Progress -> [Loc] -> [Loc]
    mscan (Just s) ps pe !acc
      | s  >= e  = acc                               -- empty interval
      | ps > pe  = scan tr isClear (d+1) (s, e) acc  -- reached end, scan next
      | not $ isClear (ps, d) =                      -- entering shadow
          let ne = (fromIntegral ps - (1%2)) / (fromIntegral d + (1%2))
          in scan tr isClear (d+1) (s, ne) (mscan Nothing (ps+1) pe acc)
      | otherwise = mscan (Just s) (ps+1) pe acc     -- continue in light

    mscan Nothing ps pe !acc
      | ps > pe  = acc                  -- reached end while in shadow
      | isClear (ps, d) =               -- moving out of shadow
          let ns = (fromIntegral ps - (1%2)) / (fromIntegral d - (1%2))
          in mscan (Just ns) (ps+1) pe acc
      | otherwise =                     -- continue in shadow
           mscan Nothing (ps+1) pe acc


downBias, upBias :: (Integral a, Integral b) => Ratio a -> b
downBias x = round (x - 1 % (denominator x * 3))
upBias   x = round (x + 1 % (denominator x * 3))
