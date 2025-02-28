{-# LANGUAGE TupleSections #-}
-- | Server operations common to many modules.
module Game.LambdaHack.Server.CommonM
  ( revealItems, moveStores, generalMoveItem
  , deduceQuits, deduceKilled, electLeader, setFreshLeader
  , updatePer, recomputeCachePer, projectFail
  , addActorFromGroup, registerActor, discoverIfMinorEffects
  , pickWeaponServer, currentSkillsServer, allGroupItems
  , addCondition, removeConditionSingle, addSleep, removeSleepSingle
  , addKillToAnalytics
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , containerMoveItem, quitF, keepArenaFact, anyActorsAlive, projectBla
  , addProjectile, addActorIid, getCacheLucid, getCacheTotal
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.Ord as Ord
import           Data.Ratio

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client (ClientOptions (..))
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Analytics
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Perception
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Core.Random
import qualified Game.LambdaHack.Definition.Ability as Ability
import           Game.LambdaHack.Definition.Defs
import           Game.LambdaHack.Server.Fov
import           Game.LambdaHack.Server.ItemM
import           Game.LambdaHack.Server.ItemRev
import           Game.LambdaHack.Server.MonadServer
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

revealItems :: MonadServerAtomic m => FactionId -> m ()
revealItems fid = do
  COps{coitem} <- getsState scops
  ServerOptions{sclientOptions} <- getsServer soptions
  discoAspect <- getsState sdiscoAspect
  let discover aid store iid _ = do
        itemKindId <- getsState $ getIidKindIdServer iid
        let arItem = discoAspect EM.! iid
            c = CActor aid store
            itemKind = okind coitem itemKindId
        unless (IA.isHumanTrinket itemKind) $  -- a hack
          execUpdAtomic $ UpdDiscover c iid itemKindId arItem
      f (aid, b) =
        -- CStash is IDed for each actor of each faction, which is fine,
        -- even though it may introduce a slight lag at gameover.
        join $ getsState $ mapActorItems_ (discover aid) b
  -- Don't ID projectiles, their items are not really owned by the party.
  aids <- getsState $ fidActorNotProjGlobalAssocs fid
  mapM_ f aids
  dungeon <- getsState sdungeon
  let minLid = fst $ minimumBy (Ord.comparing (ldepth . snd))
                   $ EM.assocs dungeon
      discoverSample iid = do
        itemKindId <- getsState $ getIidKindIdServer iid
        let arItem = discoAspect EM.! iid
            cdummy = CTrunk fid minLid originPoint  -- only @fid@ matters here
            itemKind = okind coitem itemKindId
        execUpdAtomic $ if IA.isHumanTrinket itemKind  -- a hack
                        then UpdSpotItem False iid (1, []) cdummy
                        else UpdDiscover cdummy iid itemKindId arItem
  generationAn <- getsServer sgenerationAn
  getKindId <- getsState $ flip getIidKindIdServer
  let kindsEqual iid iid2 = getKindId iid == getKindId iid2 && iid /= iid2
      nonDupSample em iid 0 = not $ any (kindsEqual iid) $ EM.keys em
      nonDupSample _ _ _ = True
      nonDupGen = EM.map (\em -> EM.filterWithKey (nonDupSample em) em)
                         generationAn
  -- Remove samples that are supplanted by real items.
  -- If there are mutliple UI factions, the second run will be vacuus,
  -- but it's important to do that before the first try to identify things
  -- to prevent spam from identifying samples that are not needed.
  modifyServer $ \ser -> ser {sgenerationAn = nonDupGen}
  when (sexposeActors sclientOptions) $
    -- Few, if any, need ID, but we can't rule out unusual content.
    mapM_ discoverSample $ EM.keys $ nonDupGen EM.! STrunk
  when (sexposeItems sclientOptions) $
    mapM_ discoverSample $ EM.keys $ nonDupGen EM.! SItem
  mapM_ discoverSample $ EM.keys $ nonDupGen EM.! SEmbed
  mapM_ discoverSample $ EM.keys $ nonDupGen EM.! SOrgan
  mapM_ discoverSample $ EM.keys $ nonDupGen EM.! SCondition
  mapM_ discoverSample $ EM.keys $ nonDupGen EM.! SBlast

moveStores :: MonadServerAtomic m
           => Bool -> ActorId -> CStore -> CStore -> m ()
moveStores verbose aid fromStore toStore = do
  b <- getsState $ getActorBody aid
  let g iid (k, _) = do
        move <- generalMoveItem verbose iid k (CActor aid fromStore)
                                              (CActor aid toStore)
        mapM_ execUpdAtomic move
  mapActorCStore_ fromStore g b

-- | Generate the atomic updates that jointly perform a given item move.
generalMoveItem :: MonadStateRead m
                => Bool -> ItemId -> Int -> Container -> Container
                -> m [UpdAtomic]
generalMoveItem _ iid k (CActor aid1 cstore1) c2@(CActor aid2 cstore2)
  | aid1 == aid2 = do
    moveStash <- moveStashIfNeeded c2
    return $! moveStash ++ [UpdMoveItem iid k aid1 cstore1 cstore2]
generalMoveItem verbose iid k c1 c2 = containerMoveItem verbose iid k c1 c2

containerMoveItem :: MonadStateRead m
                  => Bool -> ItemId -> Int -> Container -> Container
                  -> m [UpdAtomic]
containerMoveItem verbose iid k c1 c2 = do
  bag <- getsState $ getContainerBag c1
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (iid, k, c1, c2)
    Just (_, it) -> do
      moveStash <- moveStashIfNeeded c2
      return $ [UpdLoseItem verbose iid (k, take k it) c1]
               ++ moveStash
               ++ [UpdSpotItem verbose iid (k, take k it) c2]

quitF :: MonadServerAtomic m => Status -> FactionId -> m ()
quitF status fid = do
  fact <- getsState $ (EM.! fid) . sfactionD
  let oldSt = gquit fact
  -- Note that it's the _old_ status that we check here.
  case stOutcome <$> oldSt of
    Just Killed -> return ()    -- Do not overwrite in case
    Just Defeated -> return ()  -- many things happen in 1 turn.
    Just Conquer -> return ()
    Just Escape -> return ()
    _ -> do
      -- This runs regardless of the _new_ status.
      manalytics <-
        if fhasUI $ gplayer fact then do
          keepAutomated <- getsServer $ skeepAutomated . soptions
          -- Try to remove AI control of the UI faction, to show endgame info.
          when (isAIFact fact
                && fleaderMode (gplayer fact) /= LeaderNull
                && not keepAutomated) $
            execUpdAtomic $ UpdAutoFaction fid False
          revealItems fid
          -- Likely, by this time UI faction is no longer AI-controlled,
          -- so the score will get registered.
          registerScore status fid
          factionAn <- getsServer sfactionAn
          generationAn <- getsServer sgenerationAn
          return $ Just (factionAn, generationAn)
        else return Nothing
      execUpdAtomic $ UpdQuitFaction fid oldSt (Just status) manalytics
      modifyServer $ \ser -> ser {sbreakLoop = True}  -- check game over

-- Send any UpdQuitFaction actions that can be deduced from factions'
-- current state.
deduceQuits :: MonadServerAtomic m => FactionId -> Status -> m ()
deduceQuits fid0 status@Status{stOutcome}
  | stOutcome `elem` [Defeated, Camping, Restart, Conquer] =
    error $ "no quitting to deduce" `showFailure` (fid0, status)
deduceQuits fid0 status = do
  fact0 <- getsState $ (EM.! fid0) . sfactionD
  let factHasUI = fhasUI . gplayer
      quitFaction (stOutcome, (fid, _)) = quitF status{stOutcome} fid
      mapQuitF outfids = do
        let (withUI, withoutUI) =
              partition (factHasUI . snd . snd)
                        ((stOutcome status, (fid0, fact0)) : outfids)
        mapM_ quitFaction (withoutUI ++ withUI)
      inGameOutcome (fid, fact) = do
        let mout | fid == fid0 = Just $ stOutcome status
                 | otherwise = stOutcome <$> gquit fact
        case mout of
          Just Killed -> False
          Just Defeated -> False
          Just Restart -> False  -- effectively, commits suicide
          _ -> True
  factionD <- getsState sfactionD
  let assocsInGame = filter inGameOutcome $ EM.assocs factionD
      assocsKeepArena = filter (keepArenaFact . snd) assocsInGame
      assocsUI = filter (factHasUI . snd) assocsInGame
      nonHorrorAIG = filter (not . isHorrorFact . snd) assocsInGame
      worldPeace =
        all (\(fid1, _) -> all (\(fid2, fact2) -> not $ isFoe fid2 fact2 fid1)
                           nonHorrorAIG)
        nonHorrorAIG
      othersInGame = filter ((/= fid0) . fst) assocsInGame
  if | null assocsUI ->
       -- Only non-UI players left in the game and they all win.
       mapQuitF $ zip (repeat Conquer) othersInGame
     | null assocsKeepArena ->
       -- Only leaderless and spawners remain (the latter may sometimes
       -- have no leader, just as the former), so they win,
       -- or we could get stuck in a state with no active arena
       -- and so no spawns.
       mapQuitF $ zip (repeat Conquer) othersInGame
     | worldPeace ->
       -- Nobody is at war any more, so all win (e.g., horrors, but never mind).
       mapQuitF $ zip (repeat Conquer) othersInGame
     | stOutcome status == Escape -> do
       -- Otherwise, in a game with many warring teams alive,
       -- only complete Victory matters, until enough of them die.
       let (victors, losers) =
             partition (\(fi, _) -> isFriend fid0 fact0 fi) othersInGame
       mapQuitF $ zip (repeat Escape) victors ++ zip (repeat Defeated) losers
     | otherwise -> quitF status fid0

-- | Tell whether a faction that we know is still in game, keeps arena.
-- Keeping arena means, if the faction is still in game,
-- it always has a leader in the dungeon somewhere.
-- So, leaderless factions and spawner factions do not keep an arena,
-- even though the latter usually has a leader for most of the game.
keepArenaFact :: Faction -> Bool
keepArenaFact fact = fleaderMode (gplayer fact) /= LeaderNull
                     && fneverEmpty (gplayer fact)

-- We assume the actor in the second argument has HP <= 0 or is going to be
-- dominated right now. Even if the actor is to be dominated,
-- @bfid@ of the actor body is still the old faction.
deduceKilled :: MonadServerAtomic m => ActorId -> m ()
deduceKilled aid = do
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  when (fneverEmpty $ gplayer fact) $ do
    actorsAlive <- anyActorsAlive (bfid body) aid
    when (not actorsAlive) $
      deduceQuits (bfid body) $ Status Killed (fromEnum $ blid body) Nothing

anyActorsAlive :: MonadServer m => FactionId -> ActorId -> m Bool
anyActorsAlive fid aid = do
  as <- getsState $ fidActorNotProjGlobalAssocs fid
  -- We test HP here, in case more than one actor goes to 0 HP in the same turn.
  return $! any (\(aid2, b2) -> aid2 /= aid && bhp b2 > 0) as

electLeader :: MonadServerAtomic m => FactionId -> LevelId -> ActorId -> m ()
electLeader fid lid aidToReplace = do
  mleader <- getsState $ gleader . (EM.! fid) . sfactionD
  when (mleader == Just aidToReplace) $ do
    allOurs <- getsState $ fidActorNotProjGlobalAssocs fid  -- not only on level
    let -- Prefer actors on this level and with positive HP and not sleeping.
        -- Exclude @aidToReplace@, even if not dead (e.g., if being dominated).
        (positive, negative) = partition (\(_, b) -> bhp b > 0) allOurs
        (awake, sleeping) = partition (\(_, b) -> bwatch b /= WSleep) positive
    onThisLevel <- getsState $ fidActorRegularAssocs fid lid
    let candidates = filter (\(_, b) -> bwatch b /= WSleep) onThisLevel
                     ++ awake ++ sleeping ++ negative
        mleaderNew =
          listToMaybe $ filter (/= aidToReplace) $ map fst $ candidates
    execUpdAtomic $ UpdLeadFaction fid mleader mleaderNew

setFreshLeader :: MonadServerAtomic m => FactionId -> ActorId -> m ()
setFreshLeader fid aid = do
  fact <- getsState $ (EM.! fid) . sfactionD
  unless (fleaderMode (gplayer fact) == LeaderNull) $ do
    -- First update and send Perception so that the new leader
    -- may report his environment.
    b <- getsState $ getActorBody aid
    let !_A = assert (not $ bproj b) ()
    valid <- getsServer $ (EM.! blid b) . (EM.! fid) . sperValidFid
    unless valid $ updatePer fid (blid b)
    execUpdAtomic $ UpdLeadFaction fid (gleader fact) (Just aid)

updatePer :: MonadServerAtomic m => FactionId -> LevelId -> m ()
{-# INLINE updatePer #-}
updatePer fid lid = do
  modifyServer $ \ser ->
    ser {sperValidFid = EM.adjust (EM.insert lid True) fid $ sperValidFid ser}
  sperFidOld <- getsServer sperFid
  let perOld = sperFidOld EM.! fid EM.! lid
  -- Performed in the State after action, e.g., with a new actor.
  perNew <- recomputeCachePer fid lid
  let inPer = diffPer perNew perOld
      outPer = diffPer perOld perNew
  unless (nullPer outPer && nullPer inPer) $
    execSendPer fid lid outPer inPer perNew

recomputeCachePer :: MonadServer m => FactionId -> LevelId -> m Perception
recomputeCachePer fid lid = do
  total <- getCacheTotal fid lid
  fovLucid <- getCacheLucid lid
  perNew <- getsState $ perceptionFromPTotal fid lid fovLucid total
  let fper = EM.adjust (EM.insert lid perNew) fid
  modifyServer $ \ser -> ser {sperFid = fper $ sperFid ser}
  return perNew

-- The missile item is removed from the store only if the projection
-- went into effect (no failure occured).
projectFail :: MonadServerAtomic m
            => ActorId    -- ^ actor causing the projection
            -> ActorId    -- ^ actor projecting the item (is on current lvl)
            -> Point      -- ^ target position of the projectile
            -> Int        -- ^ digital line parameter
            -> Bool       -- ^ whether to start at the source position
            -> ItemId     -- ^ the item to be projected
            -> CStore     -- ^ which store the items comes from
            -> Bool       -- ^ whether the item is a blast
            -> m (Maybe ReqFailure)
projectFail propeller source tpxy eps center iid cstore blast = do
  COps{corule=RuleContent{rXmax, rYmax}, coTileSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
      spos = bpos sb
  lvl <- getLevel lid
  case bla rXmax rYmax eps spos tpxy of
    Nothing -> return $ Just ProjectAimOnself
    Just [] -> error $ "projecting from the edge of level"
                       `showFailure` (spos, tpxy)
    Just (pos : restUnlimited) -> do
      bag <- getsState $ getBodyStoreBag sb cstore
      case EM.lookup iid bag of
        Nothing -> return $ Just ProjectOutOfReach
        Just _kit -> do
          itemFull <- getsState $ itemToFull iid
          actorSk <- currentSkillsServer source
          actorMaxSk <- getsState $ getActorMaxSkills source
          let skill = Ability.getSk Ability.SkProject actorSk
              forced = blast || bproj sb
              calmE = calmEnough sb actorMaxSk
              legal = permittedProject forced skill calmE itemFull
              arItem = aspectRecordFull itemFull
          case legal of
            Left reqFail -> return $ Just reqFail
            Right _ -> do
              let lobable = IA.checkFlag Ability.Lobable arItem
                  rest = if lobable
                         then take (chessDist spos tpxy - 1) restUnlimited
                         else restUnlimited
                  t = lvl `at` pos
              if | not $ Tile.isWalkable coTileSpeedup t ->
                   return $ Just ProjectBlockTerrain
                 | occupiedBigLvl pos lvl ->
                   if blast && bproj sb then do
                      -- Hit the blocking actor.
                      projectBla propeller source spos (pos:rest)
                                 iid cstore blast
                      return Nothing
                   else return $ Just ProjectBlockActor
                 | otherwise -> do
                   -- Make the explosion less regular and weaker at edges.
                   if blast && bproj sb && center then
                     -- Start in the center, not around.
                     projectBla propeller source spos (pos:rest)
                                iid cstore blast
                   else
                     projectBla propeller source pos rest iid cstore blast
                   return Nothing

projectBla :: MonadServerAtomic m
           => ActorId    -- ^ actor causing the projection
           -> ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ starting point of the projectile
           -> [Point]    -- ^ rest of the trajectory of the projectile
           -> ItemId     -- ^ the item to be projected
           -> CStore     -- ^ which store the items comes from
           -> Bool       -- ^ whether the item is a blast
           -> m ()
projectBla propeller source pos rest iid cstore blast = do
  sb <- getsState $ getActorBody source
  let lid = blid sb
  localTime <- getsState $ getLocalTime lid
  unless blast $ execSfxAtomic $ SfxProject source iid
  bag <- getsState $ getBodyStoreBag sb cstore
  ItemFull{itemKind} <- getsState $ itemToFull iid
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (source, pos, rest, iid, cstore)
    Just kit@(_, it) -> do
      let delay =
            if IK.iweight itemKind == 0
            then timeTurn  -- big delay at start, e.g., to easily read hologram
            else timeZero  -- avoid running into own projectiles
          btime = absoluteTimeAdd delay localTime
      addProjectile propeller pos rest iid kit lid (bfid sb) btime
      let c = CActor source cstore
      execUpdAtomic $ UpdLoseItem False iid (1, take 1 it) c

addActorFromGroup :: MonadServerAtomic m
                  => GroupName ItemKind -> FactionId -> Point -> LevelId -> Time
                  -> m (Maybe ActorId)
addActorFromGroup actorGroup bfid pos lid time = do
  -- We bootstrap the actor by first creating the trunk of the actor's body
  -- that contains the fixed properties of all actors of that kind.
  freq <- prepareItemKind 0 lid [(actorGroup, 1)]
  m2 <- rollItemAspect freq lid
  case m2 of
    Nothing -> return Nothing
    Just (itemKnown, itemFullKit) ->
      Just <$> registerActor False itemKnown itemFullKit bfid pos lid time

registerActor :: MonadServerAtomic m
              => Bool -> ItemKnown -> ItemFullKit
              -> FactionId -> Point -> LevelId -> Time
              -> m ActorId
registerActor summoned (ItemKnown kindIx ar _) (itemFullRaw, kit)
              bfid pos lid time = do
  let container = CTrunk bfid lid pos
      jfid = Just bfid
      itemKnown = ItemKnown kindIx ar jfid
      itemFull = itemFullRaw {itemBase = (itemBase itemFullRaw) {jfid}}
  trunkId <- registerItem False (itemFull, kit) itemKnown container
  aid <- addNonProjectile summoned trunkId (itemFull, kit) bfid pos lid time
  fact <- getsState $ (EM.! bfid) . sfactionD
  actorMaxSk <- getsState $ getActorMaxSkills aid
  condAnyFoeAdj <- getsState $ anyFoeAdj aid
  when (canSleep actorMaxSk &&
        not condAnyFoeAdj
        && not summoned
        && not (fhasGender (gplayer fact))) $ do  -- heroes never start asleep
    let sleepOdds = if prefersSleep actorMaxSk then 9%10 else 1%2
    sleeps <- rndToAction $ chance sleepOdds
    when sleeps $ addSleep aid
  return aid

addProjectile :: MonadServerAtomic m
              => ActorId -> Point -> [Point] -> ItemId -> ItemQuant -> LevelId
              -> FactionId -> Time
              -> m ()
addProjectile propeller pos rest iid (_, it) lid fid time = do
  itemFull <- getsState $ itemToFull iid
  let arItem = aspectRecordFull itemFull
      IK.ThrowMod{IK.throwHP} = IA.aToThrow arItem
      (trajectory, (speed, _)) =
        IA.itemTrajectory arItem (itemKind itemFull) (pos : rest)
      -- Trunk is added to equipment, not to organs, because it's the
      -- projected item, so it's carried, not grown.
      tweakBody b = b { bhp = xM throwHP
                      , btrajectory = Just (trajectory, speed)
                      , beqp = EM.singleton iid (1, take 1 it) }
  aid <- addActorIid iid itemFull True fid pos lid tweakBody
  bp <- getsState $ getActorBody propeller
  -- If propeller is a projectile, it may produce other projectiles, e.g.,
  -- by exploding, so it's not voluntary, so others are to blame.
  -- However, we can't easily see whether a pushed non-projectile actor
  -- produced a projectile due to colliding or voluntarily, so we assign
  -- blame to him.
  originator <- if bproj bp
                then getsServer $ EM.findWithDefault propeller propeller
                                  . strajPushedBy
                else return propeller
  modifyServer $ \ser ->
    ser { strajTime = updateActorTime fid lid aid time $ strajTime ser
        , strajPushedBy = EM.insert aid originator $ strajPushedBy ser }

addNonProjectile :: MonadServerAtomic m
                 => Bool -> ItemId -> ItemFullKit -> FactionId -> Point
                 -> LevelId -> Time
                 -> m ActorId
addNonProjectile summoned trunkId (itemFull, kit) fid pos lid time = do
  let tweakBody b = b { borgan = EM.singleton trunkId kit
                      , bcalm = if summoned
                                then xM 5  -- a tiny buffer before domination
                                else bcalm b }
  aid <- addActorIid trunkId itemFull False fid pos lid tweakBody
  -- We assume actor is never born pushed.
  modifyServer $ \ser ->
    ser {sactorTime = updateActorTime fid lid aid time $ sactorTime ser}
  return aid

addActorIid :: MonadServerAtomic m
            => ItemId -> ItemFull -> Bool -> FactionId -> Point -> LevelId
            -> (Actor -> Actor)
            -> m ActorId
addActorIid trunkId ItemFull{itemBase, itemKind, itemDisco=ItemDiscoFull arItem}
            bproj fid pos lid tweakBody = do
  -- Initial HP and Calm is based only on trunk and ignores organs.
  let trunkMaxHP = max 2 $ IA.getSkill Ability.SkMaxHP arItem
      hp = xM trunkMaxHP `div` 2
      -- Hard to auto-id items that refill Calm, but reduced sight at game
      -- start is more confusing and frustrating:
      calm = xM (max 0 $ IA.getSkill Ability.SkMaxCalm arItem)
  -- Create actor.
  factionD <- getsState sfactionD
  curChalSer <- getsServer $ scurChalSer . soptions
  -- If difficulty is below standard, HP is added to the UI factions,
  -- otherwise HP is added to their enemies.
  -- If no UI factions, their role is taken by the escapees (for testing).
  let diffBonusCoeff = difficultyCoeff $ cdiff curChalSer
      boostFact = not bproj
                  && if diffBonusCoeff > 0
                     then any (fhasUI . gplayer . snd)
                              (filter (\(fi, fa) -> isFriend fi fa fid)
                                      (EM.assocs factionD))
                     else any (fhasUI . gplayer  . snd)
                              (filter (\(fi, fa) -> isFoe fi fa fid)
                                      (EM.assocs factionD))
      finalHP | boostFact = min (xM 899)  -- no more than UI can stand
                                (hp * 2 ^ abs diffBonusCoeff)
              | otherwise = hp
      maxHP = min (finalHP + xM 100) (2 * finalHP)
        -- prevent too high max HP resulting in panic when low HP/max HP ratio
      bonusHP = fromEnum (maxHP `div` oneM) - trunkMaxHP
      healthOrgans = [ (Just bonusHP, ("bonus HP", COrgan))
                     | bonusHP /= 0 && not bproj ]
      b = actorTemplate trunkId finalHP calm pos lid fid bproj
      withTrunk =
        b {bweapon = if IA.checkFlag Ability.Meleeable arItem then 1 else 0}
      bodyTweaked = tweakBody withTrunk
  aid <- getsServer sacounter
  modifyServer $ \ser -> ser {sacounter = succ aid}
  execUpdAtomic $ UpdCreateActor aid bodyTweaked [(trunkId, itemBase)]
  -- Create, register and insert all initial actor items, including
  -- the bonus health organs from difficulty setting.
  forM_ (healthOrgans ++ map (Nothing,) (IK.ikit itemKind))
        $ \(mk, (ikText, cstore)) -> do
    let container = CActor aid cstore
        itemFreq = [(ikText, 1)]
    mIidEtc <- rollAndRegisterItem False lid itemFreq container mk
    case mIidEtc of
      Nothing -> error $ "" `showFailure` (lid, itemFreq, container, mk)
      Just (iid, (itemFull2, _)) ->
        when (cstore /= CGround) $
          -- The items are created owned by actors, so won't be picked up,
          -- so we have to discover them now, if eligible.
          discoverIfMinorEffects container iid (itemKindId itemFull2)
  return aid
addActorIid _ _ _ _ _ _ _ = error "addActorIid: server ignorant about an item"

discoverIfMinorEffects :: MonadServerAtomic m
                       => Container -> ItemId -> ContentId ItemKind -> m ()
discoverIfMinorEffects c iid itemKindId = do
  COps{coitem} <- getsState scops
  discoAspect <- getsState sdiscoAspect
  let arItem = discoAspect EM.! iid
      itemKind = okind coitem itemKindId
   -- Otherwise, discover by use when item's effects get activated later on.
  when (IA.onlyMinorEffects arItem itemKind
        && not (IA.isHumanTrinket itemKind)) $
    execUpdAtomic $ UpdDiscover c iid itemKindId arItem

pickWeaponServer :: MonadServer m => ActorId -> m (Maybe (ItemId, CStore))
pickWeaponServer source = do
  eqpAssocs <- getsState $ kitAssocs source [CEqp]
  bodyAssocs <- getsState $ kitAssocs source [COrgan]
  actorSk <- currentSkillsServer source
  sb <- getsState $ getActorBody source
  let kitAssRaw = eqpAssocs ++ bodyAssocs
      forced = bproj sb
      kitAss | forced = kitAssRaw  -- for projectiles, anything is weapon
             | otherwise =
                 filter (IA.checkFlag Ability.Meleeable
                         . aspectRecordFull . fst . snd) kitAssRaw
  -- Server ignores item effects or it would leak item discovery info.
  -- In particular, it even uses weapons that would heal opponent,
  -- and not only in case of projectiles.
  strongest <- pickWeaponM False Nothing kitAss actorSk source
  case strongest of
    [] -> return Nothing
    iis@((maxS, _) : _) -> do
      let maxIis = map snd $ takeWhile ((== maxS) . fst) iis
      (_, (iid, _)) <- rndToAction $ oneOf maxIis
      let cstore = if isJust (lookup iid bodyAssocs) then COrgan else CEqp
      return $ Just (iid, cstore)

-- @MonadStateRead@ would be enough, but the logic is sound only on server.
currentSkillsServer :: MonadServer m => ActorId -> m Ability.Skills
currentSkillsServer aid  = do
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  let mleader = gleader fact
  getsState $ actorCurrentSkills mleader aid

getCacheLucid :: MonadServer m => LevelId -> m FovLucid
getCacheLucid lid = do
  fovClearLid <- getsServer sfovClearLid
  fovLitLid <- getsServer sfovLitLid
  fovLucidLid <- getsServer sfovLucidLid
  let getNewLucid = getsState $ \s ->
        lucidFromLevel fovClearLid fovLitLid s lid (sdungeon s EM.! lid)
  case EM.lookup lid fovLucidLid of
    Just (FovValid fovLucid) -> return fovLucid
    _ -> do
      newLucid <- getNewLucid
      modifyServer $ \ser ->
        ser {sfovLucidLid = EM.insert lid (FovValid newLucid)
                            $ sfovLucidLid ser}
      return newLucid

getCacheTotal :: MonadServer m => FactionId -> LevelId -> m CacheBeforeLucid
getCacheTotal fid lid = do
  sperCacheFidOld <- getsServer sperCacheFid
  let perCacheOld = sperCacheFidOld EM.! fid EM.! lid
  case ptotal perCacheOld of
    FovValid total -> return total
    FovInvalid -> do
      actorMaxSkills <- getsState sactorMaxSkills
      fovClearLid <- getsServer sfovClearLid
      getActorB <- getsState $ flip getActorBody
      let perActorNew =
            perActorFromLevel (perActor perCacheOld) getActorB
                              actorMaxSkills (fovClearLid EM.! lid)
          -- We don't check if any actor changed, because almost surely one is.
          -- Exception: when an actor is destroyed, but then union differs, too.
          total = totalFromPerActor perActorNew
          perCache = PerceptionCache { ptotal = FovValid total
                                     , perActor = perActorNew }
          fperCache = EM.adjust (EM.insert lid perCache) fid
      modifyServer $ \ser -> ser {sperCacheFid = fperCache $ sperCacheFid ser}
      return total

allGroupItems :: MonadServerAtomic m
              => CStore -> GroupName ItemKind -> ActorId
              -> m [(ItemId, ItemQuant)]
allGroupItems store grp target = do
  b <- getsState $ getActorBody target
  getKind <- getsState $ flip getIidKindServer
  let hasGroup (iid, _) =
        maybe False (> 0) $ lookup grp $ IK.ifreq $ getKind iid
  assocsCStore <- getsState $ EM.assocs . getBodyStoreBag b store
  return $! filter hasGroup assocsCStore

addCondition :: MonadServerAtomic m => Bool -> GroupName ItemKind -> ActorId -> m ()
addCondition verbose name aid = do
  b <- getsState $ getActorBody aid
  let c = CActor aid COrgan
  mresult <- rollAndRegisterItem verbose (blid b) [(name, 1)] c Nothing
  assert (isJust mresult) $ return ()

removeConditionSingle :: MonadServerAtomic m
                      => GroupName ItemKind -> ActorId -> m Int
removeConditionSingle name aid = do
  let c = CActor aid COrgan
  is <- allGroupItems COrgan name aid
  case is of
    [(iid, (nAll, itemTimer))] -> do
      execUpdAtomic $ UpdLoseItem False iid (1, itemTimer) c
      return $ nAll - 1
    _ -> error $ "missing or multiple item" `showFailure` (name, is)

addSleep :: MonadServerAtomic m => ActorId -> m ()
addSleep aid = do
  b <- getsState $ getActorBody aid
  addCondition True "asleep" aid
  execUpdAtomic $ UpdWaitActor aid (bwatch b) WSleep

removeSleepSingle :: MonadServerAtomic m => ActorId -> m ()
removeSleepSingle aid = do
  nAll <- removeConditionSingle "asleep" aid
  when (nAll == 0) $
    execUpdAtomic $ UpdWaitActor aid WWake WWatch

addKillToAnalytics :: MonadServerAtomic m
                   => ActorId -> KillHow -> FactionId -> ItemId -> m ()
addKillToAnalytics aid killHow fid iid = do
  actorD <- getsState sactorD
  case EM.lookup aid actorD of
    Just b ->
      modifyServer $ \ser ->
        ser { sfactionAn = addFactionKill (bfid b) killHow fid iid
                           $ sfactionAn ser
            , sactorAn = addActorKill aid killHow fid iid
                         $ sactorAn ser }
    Nothing -> return ()  -- killer dead, too late to assign blame
