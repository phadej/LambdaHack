-- | Picking the AI actor to move and refreshing leader and non-leader targets.
module Game.LambdaHack.Client.AI.PickActorM
  ( pickActorToMove, setTargetFromDoctrines
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM
import           Data.Ratio

import           Game.LambdaHack.Client.AI.ConditionM
import           Game.LambdaHack.Client.AI.PickTargetM
import           Game.LambdaHack.Client.Bfs
import           Game.LambdaHack.Client.BfsM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Core.Frequency
import           Game.LambdaHack.Core.Random
import qualified Game.LambdaHack.Definition.Ability as Ability

-- | Pick a new leader from among the actors on the current level.
-- Refresh the target of the new leader, even if unchanged.
pickActorToMove :: MonadClient m => Maybe ActorId -> m ActorId
{-# INLINE pickActorToMove #-}
pickActorToMove maidToAvoid = do
  actorMaxSkills <- getsState sactorMaxSkills
  mleader <- getsClient sleader
  let oldAid = fromMaybe (error $ "" `showFailure` maidToAvoid) mleader
  oldBody <- getsState $ getActorBody oldAid
  let side = bfid oldBody
      arena = blid oldBody
  fact <- getsState $ (EM.! side) . sfactionD
  -- Find our actors on the current level only.
  ours <- getsState $ fidActorRegularAssocs side arena
  let pickOld = do
        void $ refreshTarget (oldAid, oldBody)
        return oldAid
      oursNotSleeping = filter (\(_, b) -> bwatch b /= WSleep) ours
  case oursNotSleeping of
    _ | -- Keep the leader: faction discourages client leader change on level,
        -- so will only be changed if waits (maidToAvoid)
        -- to avoid wasting his higher mobility.
        -- This is OK for monsters even if in melee, because both having
        -- a meleeing actor a leader (and higher DPS) and rescuing actor
        -- a leader (and so faster to get in melee range) is good.
        -- And we are guaranteed that only the two classes of actors are
        -- not waiting, with some exceptions (urgent unequip, flee via starts,
        -- melee-less trying to flee, first aid, etc.).
        snd (autoDungeonLevel fact) && isNothing maidToAvoid -> pickOld
    [] -> pickOld
    [(aidNotSleeping, bNotSleeping)] -> do
      -- Target of asleep actors won't change unless foe adjacent,
      -- which is caught without recourse to targeting.
      void $ refreshTarget (aidNotSleeping, bNotSleeping)
      return aidNotSleeping
    _ -> do
      -- At this point we almost forget who the old leader was
      -- and treat all party actors the same, eliminating candidates
      -- until we can't distinguish them any more, at which point we prefer
      -- the old leader, if he is among the best candidates
      -- (to make the AI appear more human-like and easier to observe).
      let refresh aidBody = do
            mtgt <- refreshTarget aidBody
            return (aidBody, mtgt)
      oursTgtRaw <- mapM refresh oursNotSleeping
      fleeD <- getsClient sfleeD
      let goodGeneric (_, Nothing) = Nothing
          goodGeneric (_, Just TgtAndPath{tapPath=Nothing}) = Nothing
            -- this case means melee-less heroes adjacent to foes, etc.
            -- will never flee if melee is happening; but this is rare;
            -- this also ensures even if a lone actor melees and nobody
            -- can come to rescue, he will become and remain the leader,
            -- because otherwise an explorer would need to become a leader
            -- and fighter will be 1 clip slower for the whole fight,
            -- just for a few turns of exploration in return;
            --
            -- also note that when the fighter then becomes a leader
            -- he may gain quite a lot of time via @swapTime@,
            -- and so be able to get a double blow on opponents
            -- or a safe blow and a withdraw (but only once); this is a mild
            -- exploit that encourages ambush camping (with a non-leader),
            -- but it's also a rather fun exploit and a straightforward
            -- consequence of the game mechanics, so it's OK for now
          goodGeneric ((aid, b), Just tgt) = case maidToAvoid of
            Nothing | not (aid == oldAid && actorWaits b) ->
              -- Not the old leader that was stuck last turn
              -- because he is likely to be still stuck.
              Just ((aid, b), tgt)
            Just aidToAvoid | aid /= aidToAvoid ->
              -- Not an attempted leader stuck this turn.
              Just ((aid, b), tgt)
            _ -> Nothing
          oursTgt = mapMaybe goodGeneric oursTgtRaw
          -- This should be kept in sync with @actionStrategy@.
          actorVulnerable ((aid, body), _) = do
            condInMelee <- condInMeleeM $ blid body
            let actorMaxSk = actorMaxSkills EM.! aid
            threatDistL <- getsState $ meleeThreatDistList aid
            (fleeL, _) <- fleeList aid
            condSupport1 <- condSupport 1 aid
            condSupport3 <- condSupport 3 aid
            condSolo <- condSoloM aid  -- solo fighters aggresive
            canDeAmbientL <- getsState $ canDeAmbientList body
            let condCanFlee = not (null fleeL)
                speed1_5 = speedScale (3%2) (gearSpeed actorMaxSk)
                condCanMelee = actorCanMelee actorMaxSkills aid body
                condThreat n = not $ null $ takeWhile ((<= n) . fst) threatDistL
                threatAdj = takeWhile ((== 1) . fst) threatDistL
                condManyThreatAdj = length threatAdj >= 2
                condFastThreatAdj =
                  any (\(_, (aid2, _)) ->
                    let actorMaxSk2 = actorMaxSkills EM.! aid2
                    in gearSpeed actorMaxSk2 > speed1_5)
                  threatAdj
                heavilyDistressed =
                  -- Actor hit by a projectile or similarly distressed.
                  deltasSerious (bcalmDelta body)
                actorShines = Ability.getSk Ability.SkShine actorMaxSk > 0
                aCanDeLightL | actorShines = []
                             | otherwise = canDeAmbientL
                canFleeFromLight =
                  not $ null $ aCanDeLightL `intersect` map snd fleeL
            return $!
              -- This is a part of the condition for @flee@ in @PickActionM@.
              not condFastThreatAdj
              && if | condThreat 1 ->
                      not condCanMelee
                      || condManyThreatAdj && not condSupport1 && not condSolo
                    | not condInMelee
                      && (condThreat 2 || condThreat 5 && canFleeFromLight) ->
                      not condCanMelee
                      || not condSupport3 && not condSolo
                         && not heavilyDistressed
                    -- Not used: | condThreat 5 ...
                    -- because actor should be picked anyway, to try to melee.
                    | otherwise ->
                      not condInMelee
                      && heavilyDistressed
                      -- Different from @PickActionM@:
                      && not (EM.member aid fleeD)
                        -- Make him a leader even if can't delight, etc.
                        -- because he may instead take off light or otherwise
                        -- cope with being pummeled by projectiles.
                        -- He is still vulnerable, just not necessarily needs
                        -- to flee, but may cover himself otherwise.
                        -- && (not condCanProject || canFleeFromLight)
              && condCanFlee
          actorFled ((aid, _), _) = EM.member aid fleeD
          actorHearning (_, TgtAndPath{ tapTgt=TPoint TEnemyPos{} _ _
                                      , tapPath=Nothing }) =
            return False
          actorHearning (_, TgtAndPath{ tapTgt=TPoint TEnemyPos{} _ _
                                      , tapPath=Just AndPath{pathLen} })
            | pathLen <= 2 =
            return False  -- noise probably due to fleeing target
          actorHearning ((_aid, b), _) = do
            allFoes <- getsState $ foeRegularList side (blid b)
            let closeFoes = filter ((<= 3) . chessDist (bpos b) . bpos) allFoes
                actorHears = deltasHears (bcalmDelta b)
            return $! actorHears  -- e.g., actor hears an enemy
                      && null closeFoes  -- the enemy not visible; a trap!
          -- AI has to be prudent and not lightly waste leader for meleeing,
          -- even if his target is distant
          actorMeleeing ((aid, _), _) = condAnyFoeAdjM aid
      (oursVulnerable, oursSafe) <- partitionM actorVulnerable oursTgt
      let (oursFled, oursNotFled) = partition actorFled oursSafe
      (oursMeleeing, oursNotMeleeing) <- partitionM actorMeleeing oursNotFled
      (oursHearing, oursNotHearing) <- partitionM actorHearning oursNotMeleeing
      let actorRanged ((aid, body), _) =
            not $ actorCanMelee actorMaxSkills aid body
          targetTEnemy (_, TgtAndPath{tapTgt=TEnemy _}) = True
          targetTEnemy
            ( (_, b)
            , TgtAndPath{tapTgt=TPoint (TEnemyPos _) lid _} ) =
              lid == blid b
          targetTEnemy _ = False
          actorNoSupport ((aid, _), _) = do
            threatDistL <- getsState $ meleeThreatDistList aid
            condSupport2 <- condSupport 2 aid
            let condThreat n = not $ null $ takeWhile ((<= n) . fst) threatDistL
            -- If foes far, friends may still come, so we let him move.
            -- The net effect is that lone heroes close to foes freeze
            -- until support comes.
            return $! condThreat 5 && not condSupport2
          (oursRanged, oursNotRanged) = partition actorRanged oursNotHearing
          (oursTEnemyAll, oursOther) = partition targetTEnemy oursNotRanged
          notSwapReady abt@((_, b), _)
                       (ab2, Just t2@TgtAndPath{tapPath=
                                       Just AndPath{pathList=q : _}}) =
            let source = bpos b
                tenemy = targetTEnemy abt
                tenemy2 = targetTEnemy (ab2, t2)
            -- Copied from 'displaceTowards':
            in not (q == source  -- friend wants to swap
                    || tenemy && not tenemy2)
          notSwapReady _ _ = True
          -- These are not necessarily stuck (perhaps can go around),
          -- but their current path is blocked by friends.
          -- As soon as friends move, path is recalcuated and they may
          -- become unstuck.
          targetBlocked abt@((aid, _), TgtAndPath{tapPath}) = case tapPath of
            Just AndPath{pathList= q : _} ->
              any (\abt2@((aid2, body2), _) ->
                     aid2 /= aid  -- in case pushed on goal
                     && bpos body2 == q
                     && notSwapReady abt abt2)
                  oursTgtRaw
            _ -> False
          (oursTEnemyBlocked, oursTEnemy) =
            partition targetBlocked oursTEnemyAll
      (oursNoSupportRaw, oursSupportRaw) <-
        if length oursTEnemy <= 2
        then return ([], oursTEnemy)
        else partitionM actorNoSupport oursTEnemy
      let (oursNoSupport, oursSupport) =
            if length oursSupportRaw <= 1  -- make sure picks random enough
            then ([], oursTEnemy)
            else (oursNoSupportRaw, oursSupportRaw)
          (oursBlocked, oursPos) =
            partition targetBlocked $ oursRanged ++ oursOther
          -- Lower overhead is better.
          overheadOurs :: ((ActorId, Actor), TgtAndPath) -> Int
          overheadOurs ((aid, _), TgtAndPath{tapPath=Nothing}) =
            100 + if aid == oldAid then 1 else 0
          overheadOurs
            abt@( (aid, b)
                , TgtAndPath{tapPath=Just AndPath{pathLen=d,pathGoal}} ) =
            -- Keep proper formation. Too dense and exploration takes
            -- too long; too sparse and actors fight alone.
            -- Note that right now, while we set targets separately for each
            -- hero, perhaps on opposite borders of the map,
            -- we can't help that sometimes heroes are separated.
            let maxSpread = 3 + length oursNotSleeping
                lDist p = [ chessDist (bpos b2) p
                          | (aid2, b2) <- oursNotSleeping, aid2 /= aid]
                pDist p = let ld = lDist p
                          in assert (not $ null ld) $ minimum ld
                aidDist = pDist (bpos b)
                -- Negative, if the goal gets us closer to the party.
                diffDist = pDist pathGoal - aidDist
                -- If actor already at goal or equidistant, count it as closer.
                sign = if diffDist <= 0 then -1 else 1
                formationValue =
                  sign * (abs diffDist `max` maxSpread)
                  * (aidDist `max` maxSpread) ^ (2 :: Int)
                fightValue | targetTEnemy abt =
                  - fromEnum (bhp b `div` (10 * oneM))
                           | otherwise = 0
            in formationValue `div` 3 + fightValue
               + (if targetBlocked abt then 5 else 0)
               + (case d of
                    0 -> -400 -- do your thing ASAP and retarget
                    1 -> -200 -- prevent others from occupying the tile
                    _ -> if d < 8 then d `div` 4 else 2 + d `div` 10)
               + (if aid == oldAid then 1 else 0)
          positiveOverhead sk =
            let ov = 200 - overheadOurs sk
            in if ov <= 0 then 1 else ov
          candidates = [ oursVulnerable
                       , oursSupport
                       , oursNoSupport
                       , oursPos
                       , oursFled  -- if just fled, keep him safe, out of action
                       , oursMeleeing ++ oursTEnemyBlocked
                           -- make melee a leader to displace or at least melee
                           -- without overhead if all others blocked
                       , oursHearing
                       , oursBlocked
                       ]
      case filter (not . null) candidates of
        l : _ -> do
          let freq = toFreq "candidates for AI leader"
                     $ map (positiveOverhead &&& id) l
          ((aid, b), _) <- rndToAction $ frequency freq
          s <- getState
          modifyClient $ updateLeader aid s
          -- When you become a leader, stop following old leader, but follow
          -- his target, if still valid, to avoid distraction.
          condInMelee <- condInMeleeM $ blid b
          when (fdoctrine (gplayer fact)
                `elem` [Ability.TFollow, Ability.TFollowNoItems]
                && not condInMelee) $
            void $ refreshTarget (aid, b)
          return aid
        _ -> return oldAid

-- | Inspect the doctrines of the actor and set his target according to it.
setTargetFromDoctrines :: MonadClient m => ActorId -> m ()
{-# INLINE setTargetFromDoctrines #-}
setTargetFromDoctrines oldAid = do
  mleader <- getsClient sleader
  let !_A = assert (mleader /= Just oldAid) ()
  oldBody <- getsState $ getActorBody oldAid
  moldTgt <- getsClient $ EM.lookup oldAid . stargetD
  condInMelee <- condInMeleeM $ blid oldBody
  let side = bfid oldBody
      arena = blid oldBody
  fact <- getsState $ (EM.! side) . sfactionD
  let explore = void $ refreshTarget (oldAid, oldBody)
      setPath mtgt = case (mtgt, moldTgt) of
        (Nothing, _) -> return False
        ( Just TgtAndPath{tapTgt=leaderTapTgt},
          Just TgtAndPath{tapTgt=oldTapTgt,tapPath=Just oldTapPath} )
          | leaderTapTgt == oldTapTgt  -- targets agree
            && bpos oldBody == pathSource oldTapPath -> do  -- nominal path
            void $ refreshTarget (oldAid, oldBody)
            return True  -- already on target
        (Just TgtAndPath{tapTgt=leaderTapTgt}, _) -> do
            tap <- createPath oldAid leaderTapTgt
            case tap of
              TgtAndPath{tapPath=Nothing} -> return False
              _ -> do
                modifyClient $ \cli ->
                  cli {stargetD = EM.insert oldAid tap (stargetD cli)}
                return True
      follow = case mleader of
        -- If no leader at all (forced @TFollow@ doctrine on an actor
        -- from a leaderless faction), fall back to @TExplore@.
        Nothing -> explore
        _ | bwatch oldBody == WSleep ->
          -- We could check skills, but it would be more complex.
          explore
        Just leader -> do
          onLevel <- getsState $ memActor leader arena
          -- If leader not on this level, fall back to @TExplore@.
          if not onLevel || condInMelee then explore
          else do
            -- Copy over the leader's target, if any, or follow his position.
            mtgt <- getsClient $ EM.lookup leader . stargetD
            tgtPathSet <- setPath mtgt
            unless tgtPathSet $ do
              let nonEnemyPath = Just TgtAndPath { tapTgt = TNonEnemy leader
                                                 , tapPath = Nothing }
              nonEnemyPathSet <- setPath nonEnemyPath
              unless nonEnemyPathSet
                -- If no path even to the leader himself, explore.
                explore
  case fdoctrine $ gplayer fact of
    Ability.TExplore -> explore
    Ability.TFollow -> follow
    Ability.TFollowNoItems -> follow
    Ability.TMeleeAndRanged -> explore  -- needs to find ranged targets
    Ability.TMeleeAdjacent -> explore  -- probably not needed, but may change
    Ability.TBlock -> return ()  -- no point refreshing target
    Ability.TRoam -> explore  -- @TRoam@ is checked again inside @explore@
    Ability.TPatrol -> explore  -- WIP
