-- | Assorted conditions used later on in AI logic.
module Game.LambdaHack.Client.AI.ConditionM
  ( condAimEnemyPresentM
  , condAimEnemyRememberedM
  , condAimNonEnemyPresentM
  , condAimEnemyNoMeleeM
  , condInMeleeM
  , condAimCrucialM
  , condTgtNonmovingEnemyM
  , condAnyFoeAdjM
  , condAdjTriggerableM
  , meleeThreatDistList
  , condBlocksFriendsM
  , condFloorWeaponM
  , condNoEqpWeaponM
  , condCanProjectM
  , condProjectListM
  , benAvailableItems
  , hinders
  , condDesirableFloorItemM
  , benGroundItems
  , desirableItem
  , condSupport
  , condSoloM
  , condShineWouldBetrayM
  , fleeList
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM
import           Data.Ord

import           Game.LambdaHack.Client.Bfs
import           Game.LambdaHack.Client.CommonM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import qualified Game.LambdaHack.Core.Dice as Dice
import qualified Game.LambdaHack.Definition.Ability as Ability
import           Game.LambdaHack.Definition.Defs

-- All conditions are (partially) lazy, because they are not always
-- used in the strict monadic computations they are in.

-- | Require that the target enemy is visible by the party.
condAimEnemyPresentM :: MonadClient m => ActorId -> m Bool
condAimEnemyPresentM aid = do
  btarget <- getsClient $ getTarget aid
  return $ case btarget of
    Just (TEnemy _) -> True
    _ -> False

-- | Require that the target enemy is remembered on the actor's level.
condAimEnemyRememberedM :: MonadClient m => ActorId -> m Bool
condAimEnemyRememberedM aid = do
  b <- getsState $ getActorBody aid
  btarget <- getsClient $ getTarget aid
  return $ case btarget of
    Just (TPoint (TEnemyPos _) lid _) -> lid == blid b
    _ -> False

-- | Require that the target non-enemy is visible by the party.
condAimNonEnemyPresentM :: MonadClient m => ActorId -> m Bool
condAimNonEnemyPresentM aid = do
  btarget <- getsClient $ getTarget aid
  return $ case btarget of
    Just (TNonEnemy _) -> True
    _ -> False

-- | Require that the target enemy is visible by the party and doesn't melee.
condAimEnemyNoMeleeM :: MonadClient m => ActorId -> m Bool
condAimEnemyNoMeleeM aid = do
  btarget <- getsClient $ getTarget aid
  case btarget of
    Just (TEnemy aid2) -> do
      b2 <- getsState $ getActorBody aid2
      actorMaxSkills <- getsState sactorMaxSkills
      return $ actorCanMelee actorMaxSkills aid2 b2
    _ -> return False

condInMeleeM :: MonadClient m => LevelId -> m Bool
condInMeleeM lid = do
  condInMelee <- getsClient scondInMelee
  case EM.lookup lid condInMelee of
    Just inM -> return inM
    Nothing -> do
      side <- getsClient sside
      inM <- getsState $ inMelee side lid
      modifyClient $ \cli ->
        cli {scondInMelee = EM.insert lid inM condInMelee}
      return inM

-- | Require that the target is crucial to success, e.g., an item,
-- or that it's not too far away and so the changes to get it are high.
condAimCrucialM :: MonadClient m => ActorId -> m Bool
condAimCrucialM aid = do
  b <- getsState $ getActorBody aid
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  return $ case mtgtMPath of
    Just TgtAndPath{tapTgt=TEnemy _} -> True
    Just TgtAndPath{tapTgt=TPoint tgoal lid _, tapPath=Just AndPath{pathLen}} ->
      lid == blid b
      && (pathLen < 10  -- close enough to get there first
          || tgoal `notElem` [TUnknown, TKnown])
    Just TgtAndPath{tapTgt=TVector{}, tapPath=Just AndPath{pathLen}} ->
      pathLen < 7  -- the constant in @vToTgt@, where only
                   -- non-crucial targets are produced; this will also
                   -- prevent animals from sleep close to cave edges
    _ -> False  -- includes the case of target with no path

-- | Check if the target is a nonmoving enemy.
condTgtNonmovingEnemyM :: MonadClient m => ActorId -> m Bool
condTgtNonmovingEnemyM aid = do
  btarget <- getsClient $ getTarget aid
  case btarget of
    Just (TEnemy enemy) -> do
      actorMaxSk <- getsState $ getActorMaxSkills enemy
      return $ Ability.getSk Ability.SkMove actorMaxSk <= 0
    _ -> return False

-- | Require that any non-dying foe is adjacent, except projectiles
-- that (possibly) explode upon contact.
condAnyFoeAdjM :: MonadStateRead m => ActorId -> m Bool
condAnyFoeAdjM aid = getsState $ anyFoeAdj aid

-- | Require the actor stands on or adjacent to a triggerable tile
-- (e.g., stairs).
condAdjTriggerableM :: MonadClient m => ActorId -> m Bool
condAdjTriggerableM aid = do
  COps{coTileSpeedup} <- getsState scops
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  actorSk <- currentSkillsClient aid
  let alterSkill = Ability.getSk Ability.SkAlter actorSk
      alterMinSkill p = Tile.alterMinSkill coTileSpeedup $ lvl `at` p
      underFeet p = p == bpos b  -- if enter and alter, be more permissive
      -- Before items are applied (which AI attempts even if apply
      -- skills too low), tile must be alerable, hence both checks.
      hasTriggerable p = (underFeet p
                          || alterSkill >= fromEnum (alterMinSkill p))
                         && p `EM.member` lembed lvl
  return $ any hasTriggerable $ bpos b : vicinityUnsafe (bpos b)

-- | Produce the chess-distance-sorted list of non-low-HP,
-- melee-cabable foes on the level. We don't consider path-distance,
-- because we are interested in how soon the foe can close in to hit us,
-- which can diverge greately from path distance for short distances,
-- e.g., when terrain gets revealed. We don't consider non-moving actors,
-- because they can't chase us and also because they can't be aggresive
-- so to resolve the stalemate, the opposing AI has to be aggresive
-- by ignoring them and closing in to melee distance.
meleeThreatDistList :: ActorId -> State -> [(Int, (ActorId, Actor))]
meleeThreatDistList aid s =
  let actorMaxSkills = sactorMaxSkills s
      b = getActorBody aid s
      allAtWar = foeRegularAssocs (bfid b) (blid b) s
      strongActor (aid2, b2) =
        let actorMaxSk = actorMaxSkills EM.! aid2
            nonmoving = Ability.getSk Ability.SkMove actorMaxSk <= 0
        in not (hpTooLow b2 actorMaxSk || nonmoving)
           && actorCanMelee actorMaxSkills aid2 b2
      allThreats = filter strongActor allAtWar
      addDist (aid2, b2) = (chessDist (bpos b) (bpos b2), (aid2, b2))
  in sortBy (comparing fst) $ map addDist allThreats

-- | Require the actor blocks the paths of any of his party members.
condBlocksFriendsM :: MonadClient m => ActorId -> m Bool
condBlocksFriendsM aid = do
  b <- getsState $ getActorBody aid
  targetD <- getsClient stargetD
  let blocked aid2 = aid2 /= aid &&
        case EM.lookup aid2 targetD of
          Just TgtAndPath{tapPath=Just AndPath{pathList=q : _}} | q == bpos b ->
            True
          _ -> False
  any blocked <$> getsState (fidActorRegularIds (bfid b) (blid b))

-- | Require the actor stands over a weapon that would be auto-equipped,
-- if only it was a desirable item (checked elsewhere).
condFloorWeaponM :: MonadStateRead m => ActorId -> m Bool
condFloorWeaponM aid =
  any (IA.checkFlag Ability.Meleeable . aspectRecordFull . snd) <$>
    getsState (fullAssocs aid [CGround])

-- | Check whether the actor has no weapon in equipment.
condNoEqpWeaponM :: MonadStateRead m => ActorId -> m Bool
condNoEqpWeaponM aid =
  all (not . IA.checkFlag Ability.Meleeable . aspectRecordFull . snd) <$>
    getsState (fullAssocs aid [CEqp])

-- | Require that the actor can project any items.
condCanProjectM :: MonadClient m => Int -> ActorId -> m Bool
condCanProjectM skill aid =
  if skill < 1 then return False else  -- shortcut
    -- Compared to conditions in @projectItem@, range and charge are ignored,
    -- because they may change by the time the position for the fling
    -- is reached.
    not . null <$> condProjectListM skill aid

condProjectListM :: MonadClient m
                 => Int -> ActorId
                 -> m [(Benefit, CStore, ItemId, ItemFull, ItemQuant)]
condProjectListM skill aid = do
  condShineWouldBetray <- condShineWouldBetrayM aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  discoBenefit <- getsClient sdiscoBenefit
  getsState $ projectList discoBenefit skill aid
                          condShineWouldBetray condAimEnemyPresent

projectList :: DiscoveryBenefit -> Int -> ActorId -> Bool -> Bool -> State
            -> [(Benefit, CStore, ItemId, ItemFull, ItemQuant)]
projectList discoBenefit skill aid
            condShineWouldBetray condAimEnemyPresent s =
  let b = getActorBody aid s
      actorMaxSk = getActorMaxSkills aid s
      calmE = calmEnough b actorMaxSk
      condNotCalmEnough = not calmE
      heavilyDistressed =  -- Actor hit by a projectile or similarly distressed.
        deltasSerious (bcalmDelta b)
      -- This detects if the value of keeping the item in eqp is in fact < 0.
      hind = hinders condShineWouldBetray condAimEnemyPresent
                     heavilyDistressed condNotCalmEnough actorMaxSk
      q (Benefit{benInEqp, benFling}, _, _, itemFull, _) =
        let arItem = aspectRecordFull itemFull
        in benFling < 0
           && (not benInEqp  -- can't wear, so OK to risk losing or breaking
               || not (IA.checkFlag Ability.Meleeable arItem)
                    -- anything else expendable
                  && hind itemFull)  -- hinders now, so possibly often, so away!
           && permittedProjectAI skill calmE itemFull
      stores = [CStash, CGround] ++ [CEqp | calmE]
  in filter q $ benAvailableItems discoBenefit aid stores s

-- | Produce the list of items from the given stores available to the actor
-- and the items' values.
benAvailableItems :: DiscoveryBenefit -> ActorId -> [CStore] -> State
                  -> [(Benefit, CStore, ItemId, ItemFull, ItemQuant)]
benAvailableItems discoBenefit aid cstores s =
  let b = getActorBody aid s
      mstash = gstash $ sfactionD s EM.! bfid b
      ben _ CGround | mstash == Just (blid b, bpos b) = []
      ben bag cstore =
        [ (discoBenefit EM.! iid, cstore, iid, itemToFull iid s, kit)
        | (iid, kit) <- EM.assocs bag]
      benCStore cs = ben (getBodyStoreBag b cs s) cs
  in concatMap benCStore cstores

hinders :: Bool -> Bool -> Bool -> Bool -> Ability.Skills -> ItemFull
        -> Bool
hinders condShineWouldBetray condAimEnemyPresent
        heavilyDistressed condNotCalmEnough
          -- guess that enemies have projectiles and used them now or recently
        actorMaxSk itemFull =
  let arItem = aspectRecordFull itemFull
      itemShine = 0 < IA.getSkill Ability.SkShine arItem
      -- @condAnyFoeAdj@ is not checked, because it's transient and also item
      -- management is unlikely to happen during melee, anyway
      itemShineBad = condShineWouldBetray && itemShine
  in -- In the presence of enemies (seen, or unseen but distressing)
     -- actors want to hide in the dark.
     (condAimEnemyPresent || condNotCalmEnough || heavilyDistressed)
     && itemShineBad  -- even if it's a weapon, take it off
     -- Fast actors want to hit hard, because they hit much more often
     -- than receive hits.
     || gearSpeed actorMaxSk > speedWalk
        && not (IA.checkFlag Ability.Meleeable arItem)
             -- in case it's the only weapon
        && 0 > IA.getSkill Ability.SkHurtMelee arItem

-- | Require that the actor stands over a desirable item.
condDesirableFloorItemM :: MonadClient m => ActorId -> m Bool
condDesirableFloorItemM aid = not . null <$> benGroundItems aid

-- | Produce the list of items on the ground beneath the actor
-- that are worth picking up.
benGroundItems :: MonadClient m
               => ActorId
               -> m [(Benefit, CStore, ItemId, ItemFull, ItemQuant)]
benGroundItems aid = do
  cops <- getsState scops
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  discoBenefit <- getsClient sdiscoBenefit
  let canEsc = fcanEscape (gplayer fact)
      isDesirable (ben, _, _, itemFull, _) =
        desirableItem cops canEsc (benPickup ben)
                      (aspectRecordFull itemFull) (itemKind itemFull)
                      99  -- fake, becuase no time is wasted walking to item
  filter isDesirable
    <$> getsState (benAvailableItems discoBenefit aid [CGround])

desirableItem :: COps -> Bool -> Double -> IA.AspectRecord -> IK.ItemKind -> Int
              -> Bool
desirableItem COps{corule=RuleContent{rsymbolProjectile}}
              canEsc benPickup arItem itemKind k =
  let loneProjectile = IK.isymbol itemKind == rsymbolProjectile
                       && k == 1
                       && Dice.infDice (IK.icount itemKind) > 1
                            -- never generated as lone; usually means weak
      useful = if canEsc
               then benPickup > 0
                    || IA.checkFlag Ability.Precious arItem
               else -- A hack to prevent monsters from picking up
                    -- treasure meant for heroes.
                 let preciousNotUseful = IA.isHumanTrinket itemKind
                 in benPickup > 0 && not preciousNotUseful
  in useful && not loneProjectile

condSupport :: MonadClient m => Int -> ActorId -> m Bool
{-# INLINE condSupport #-}
condSupport param aid = do
  btarget <- getsClient $ getTarget aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  condAimEnemyRemembered <- condAimEnemyRememberedM aid
  getsState $ strongSupport param aid btarget
                            condAimEnemyPresent condAimEnemyRemembered

strongSupport :: Int -> ActorId -> Maybe Target -> Bool -> Bool -> State -> Bool
strongSupport param aid btarget condAimEnemyPresent condAimEnemyRemembered s =
  -- The smaller the area scanned for friends, the lower number required.
  let actorMaxSkills = sactorMaxSkills s
      actorMaxSk = actorMaxSkills EM.! aid
      n = min 2 param - Ability.getSk Ability.SkAggression actorMaxSk
      b = getActorBody aid s
      mtgtPos = aidTgtToPos aid (blid b) btarget s
      approaching b2 = case mtgtPos of
        Just tgtPos | condAimEnemyPresent || condAimEnemyRemembered ->
          chessDist (bpos b2) tgtPos <= 1 + param
        _ -> False
      closeEnough b2 = let dist = chessDist (bpos b) (bpos b2)
                       in dist > 0 && (dist <= param || approaching b2)
      closeAndStrong (aid2, b2) = closeEnough b2
                                  && actorCanMelee actorMaxSkills aid2 b2
      friends = friendRegularAssocs (bfid b) (blid b) s
      closeAndStrongFriends = filter closeAndStrong friends
  in n <= 0 || not (null (drop (n - 1) closeAndStrongFriends))
       -- optimized: length closeAndStrongFriends >= n

condSoloM :: MonadClient m => ActorId -> m Bool
condSoloM aid = do
  b <- getsState $ getActorBody aid
  let isSingleton [_] = True
      isSingleton _ = False
  isSingleton <$> getsState (friendRegularList (bfid b) (blid b))

-- | Require that the actor stands in the dark and so would be betrayed
-- by his own equipped light,
condShineWouldBetrayM :: MonadStateRead m => ActorId -> m Bool
condShineWouldBetrayM aid = do
  b <- getsState $ getActorBody aid
  aInAmbient <- getsState $ actorInAmbient b
  return $ not aInAmbient  -- tile is dark, so actor could hide

-- | Produce a list of acceptable adjacent points to flee to.
fleeList :: MonadClient m => ActorId -> m ([(Int, Point)], [(Int, Point)])
fleeList aid = do
  COps{coTileSpeedup} <- getsState scops
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  -- Prefer fleeing along the path to target, unless the target is a foe,
  -- in which case flee in the opposite direction.
  let etgtPath = case mtgtMPath of
        Just TgtAndPath{ tapPath=Just AndPath{pathList, pathGoal}
                       , tapTgt } -> case tapTgt of
          TEnemy{} -> Left pathGoal
          TPoint TEnemyPos{} _ _ -> Left pathGoal
          _ -> Right pathList
        _ -> Right []
  fleeD <- getsClient sfleeD
  -- But if fled previous turn, prefer even more fleeing further this turn.
  let eOldFleeOrTgt = case EM.lookup aid fleeD of
        Nothing -> etgtPath
        Just p -> Left p
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  posFoes <- getsState $ map bpos . foeRegularList (bfid b) (blid b)
  let myVic = vicinityUnsafe $ bpos b
      dist p | null posFoes = 100
             | otherwise = minimum $ map (chessDist p) posFoes
      dVic = map (dist &&& id) myVic
      -- Flee, if possible. Direct access required; not enough time to open.
      -- Can't be occupied.
      accWalkUnocc p = Tile.isWalkable coTileSpeedup (lvl `at` p)
                       && not (occupiedBigLvl p lvl)
                       && not (occupiedProjLvl p lvl)
      accWalkVic = filter (accWalkUnocc . snd) dVic
      gtVic = filter ((> dist (bpos b)) . fst) accWalkVic
      eqVicRaw = filter ((== dist (bpos b)) . fst) accWalkVic
      (eqVicOld, eqVic) = partition ((== boldpos b) . Just . snd) eqVicRaw
      accNonWalkUnocc p = not (Tile.isWalkable coTileSpeedup (lvl `at` p))
                          && Tile.isEasyOpen coTileSpeedup (lvl `at` p)
                          && not (occupiedBigLvl p lvl)
                          && not (occupiedProjLvl p lvl)
      accNonWalkVic = filter (accNonWalkUnocc . snd) dVic
      gtEqNonVic = filter ((>= dist (bpos b)) . fst) accNonWalkVic
      ltAllVic = filter ((< dist (bpos b)) . fst) dVic
      rewardPath mult (d, p) = case eOldFleeOrTgt of
        Right tgtPathList | p `elem` tgtPathList ->
          (100 * mult * d, p)
        Right tgtPathList | any (adjacent p) tgtPathList ->
          (10 * mult * d, p)
        Left pathGoal | bpos b /= pathGoal ->
          let venemy = towards (bpos b) pathGoal
              vflee = towards (bpos b) p
              sq = euclidDistSqVector venemy vflee
              skew = case compare sq 2 of
                GT -> 100 * sq
                EQ -> 10 * sq
                LT -> sq  -- going towards enemy (but may escape adjacent foes)
          in (mult * skew * d, p)
        _ -> (mult * d, p)  -- far from target path or even on target goal
      goodVic = map (rewardPath 10000) gtVic
                ++ map (rewardPath 100) eqVic
      badVic = map (rewardPath 1) $ gtEqNonVic ++ eqVicOld ++ ltAllVic
  return (goodVic, badVic)
