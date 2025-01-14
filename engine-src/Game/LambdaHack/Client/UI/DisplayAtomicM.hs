{-# LANGUAGE TupleSections #-}
-- | Display atomic commands received by the client.
module Game.LambdaHack.Client.UI.DisplayAtomicM
  ( displayRespUpdAtomicUI, displayRespSfxAtomicUI
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , updateItemSlot, markDisplayNeeded, lookAtMove
  , aidVerbMU, aidVerbMU0, aidVerbDuplicateMU
  , itemVerbMU, itemAidVerbMU, manyItemsAidVerbMU
  , createActorUI, destroyActorUI, spotItem, moveActor, displaceActorUI
  , moveItemUI, quitFactionUI
  , displayGameOverLoot, displayGameOverAnalytics
  , discover, ppSfxMsg, strike
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import           Data.Key (mapWithKeyM_)
import qualified Data.Ord as Ord
import qualified Data.Text as T
import           Data.Tuple
import           GHC.Exts (inline)
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client.ClientOptions
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.ActorUI
import           Game.LambdaHack.Client.UI.Animation
import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.ContentClientUI
import           Game.LambdaHack.Client.UI.DrawM
import           Game.LambdaHack.Client.UI.EffectDescription
import           Game.LambdaHack.Client.UI.Frame
import           Game.LambdaHack.Client.UI.FrameM
import           Game.LambdaHack.Client.UI.HandleHelperM
import           Game.LambdaHack.Client.UI.ItemDescription
import           Game.LambdaHack.Client.UI.ItemSlot
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.MsgM
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.SlideshowM
import           Game.LambdaHack.Client.UI.UIOptions
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
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Content.CaveKind (cdesc)
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import qualified Game.LambdaHack.Content.TileKind as TK
import qualified Game.LambdaHack.Core.Dice as Dice
import           Game.LambdaHack.Core.Frequency
import           Game.LambdaHack.Core.Random
import qualified Game.LambdaHack.Definition.Ability as Ability
import qualified Game.LambdaHack.Definition.Color as Color
import           Game.LambdaHack.Definition.Defs
import           Game.LambdaHack.Definition.Flavour

-- * RespUpdAtomicUI

-- | Visualize atomic updates sent to the client. This is done
-- in the global state after the command is executed and after
-- the client state is modified by the command.
-- Don't modify client state (except a few fields), but only client
-- session (e.g., by displaying messages). This is enforced by types.
displayRespUpdAtomicUI :: MonadClientUI m => UpdAtomic -> m ()
{-# INLINE displayRespUpdAtomicUI #-}
displayRespUpdAtomicUI cmd = case cmd of
  -- Create/destroy actors and items.
  UpdRegisterItems{} -> return ()
  UpdCreateActor aid body _ -> createActorUI True aid body
  UpdDestroyActor aid body _ -> destroyActorUI True aid body
  UpdCreateItem verbose iid _ kit c -> do
    recordItemLid iid c
    updateItemSlot c iid
    if verbose then case c of
      CActor aid store ->
        case store of
          COrgan -> do
            arItem <- getsState $ aspectRecordFromIid iid
            if | IA.checkFlag Ability.Blast arItem -> return ()
               | IA.checkFlag Ability.Condition arItem -> do
                 bag <- getsState $ getContainerBag c
                 let more = case EM.lookup iid bag of
                       Nothing -> False
                       Just kit2 -> fst kit2 /= fst kit
                     verb = MU.Text $
                       "become" <+> case fst kit of
                                      1 -> if more then "more" else ""
                                      k -> (if more then "additionally" else "")
                                           <+> tshow k <> "-fold"
                 -- This describes all such items already among organs,
                 -- which is useful, because it shows "charging".
                 itemAidVerbMU MsgBecome aid verb iid (Left Nothing)
               | otherwise -> do
                 wown <- ppContainerWownW partActorLeader True c
                 itemVerbMU MsgItemCreation iid kit
                           (MU.Text $ makePhrase $ "grow" : wown) c
          _ -> do
            wown <- ppContainerWownW partActorLeader True c
            itemVerbMU MsgItemCreation iid kit
                       (MU.Text $ makePhrase $ "appear" : wown) c
      CEmbed lid _ -> markDisplayNeeded lid
      CFloor lid _ -> do
        itemVerbMU MsgItemCreation iid kit
                   (MU.Text $ "appear" <+> ppContainer c) c
        markDisplayNeeded lid
      CTrunk{} -> return ()
    else do
      lid <- getsState $ lidFromC c
      markDisplayNeeded lid
  UpdDestroyItem verbose iid _ kit c -> do
    if verbose then do
      ownW <- ppContainerWownW partActorLeader False c
      let verb = MU.Text $ makePhrase $ "disappear from" : ownW
      itemVerbMU MsgItemDestruction iid kit verb c
    else do
      lid <- getsState $ lidFromC c
      markDisplayNeeded lid
  UpdSpotActor aid body -> createActorUI False aid body
  UpdLoseActor aid body -> destroyActorUI False aid body
  UpdSpotItem verbose iid kit c -> spotItem verbose iid kit c
  UpdLoseItem True iid kit c -> do
    ownW <- ppContainerWownW partActorLeader False c
    let verb = MU.Text $ makePhrase $ "be removed from" : ownW
    itemVerbMU MsgItemMove iid kit verb c
  UpdLoseItem{} -> return ()
  UpdSpotItemBag c bag -> do
    mapWithKeyM_ (\iid kit -> spotItem False iid kit c) bag
      -- @False@ for less spam and becuase summarized below
    case c of
      CActor aid store -> do
        let verb = MU.Text $ verbCStore store
        b <- getsState $ getActorBody aid
        fact <- getsState $ (EM.! bfid b) . sfactionD
        let underAI = isAIFact fact
        mleader <- getsClient sleader
        if Just aid == mleader && not underAI then
          manyItemsAidVerbMU MsgItemMove aid verb bag Right
        else when (not (bproj b) && bhp b > 0) $  -- don't announce death drops
          manyItemsAidVerbMU MsgItemMove aid verb bag (Left . Just)
      _ -> return ()
  UpdLoseItemBag{} -> return ()  -- rarely interesting and can be very long
  -- Move actors and items.
  UpdMoveActor aid source target -> moveActor aid source target
  UpdWaitActor{} -> return ()
  UpdDisplaceActor source target -> displaceActorUI source target
  UpdMoveItem iid k aid c1 c2 -> moveItemUI iid k aid c1 c2
  -- Change actor attributes.
  UpdRefillHP _ 0 -> return ()
  UpdRefillHP aid hpDelta -> do
    aidVerbMU MsgNumeric aid $ MU.Text
                             $ (if hpDelta > 0 then "heal" else "lose")
                               <+> tshow (abs hpDelta `divUp` oneM) <+> "HP"
    b <- getsState $ getActorBody aid
    arena <- getArenaUI
    side <- getsClient sside
    if | bproj b && (EM.null (beqp b) || isNothing (btrajectory b)) ->
           return ()  -- ignore caught proj or one hitting a wall
       | bhp b <= 0 && hpDelta < 0
         && (bfid b == side && not (bproj b) || arena == blid b) -> do
         let (firstFall, hurtExtra) = case (bfid b == side, bproj b) of
               (True, True) -> ("drop down", "tumble down")
               (True, False) -> ("fall down", "suffers woeful mutilation")
               (False, True) -> ("plummet", "crash")
               (False, False) -> ("collapse", "be reduced to a bloody pulp")
             verbDie = if alreadyDeadBefore then hurtExtra else firstFall
             alreadyDeadBefore = bhp b - hpDelta <= 0
         tfact <- getsState $ (EM.! bfid b) . sfactionD
         bUI <- getsSession $ getActorUI aid
         subjectRaw <- partActorLeader aid
         let subject = if alreadyDeadBefore || subjectRaw == "you"
                       then subjectRaw
                       else partActor bUI  -- avoid "fallen"
             msgDie = makeSentence [MU.SubjectVerbSg subject verbDie]
             targetIsFoe = isFoe (bfid b) tfact side
             targetIsFriend = isFriend (bfid b) tfact side
             msgClass | bproj b = MsgDeath
                      | targetIsFoe = MsgDeathGood
                      | targetIsFriend = MsgDeathBad
                      | otherwise = MsgDeath
         if bfid b == side && not (bproj b)
         then do
           msgAdd msgClass $ msgDie
           displayMore ColorBW "Alas!"
         else
           msgAdd msgClass $ msgDie <> if bproj b then "" else "\n"
         -- We show death anims only if not dead already before this refill.
         let deathAct
               | alreadyDeadBefore =
                 twirlSplash (bpos b, bpos b) Color.Red Color.Red
               | bfid b == side = deathBody (bpos b)
               | otherwise = shortDeathBody (bpos b)
         unless (bproj b) $ animate (blid b) deathAct
       | otherwise -> do
         when (hpDelta >= bhp b && bhp b > 0) $
           aidVerbMU MsgWarning aid "return from the brink of death"
         mleader <- getsClient sleader
         when (Just aid == mleader) $ do
           actorMaxSk <- getsState $ getActorMaxSkills aid
           -- Regenerating actors never stop gaining HP, so we need to stop
           -- reporting it after they reach full HP for the first time.
           -- Also, no spam for non-leaders.
           when (bhp b >= xM (Ability.getSk Ability.SkMaxHP actorMaxSk)
                 && bhp b - hpDelta < xM (Ability.getSk Ability.SkMaxHP
                                                  actorMaxSk)) $
             msgAdd MsgVeryRare "You recover your health fully. Any further gains will be transient."
         when (bfid b == side && not (bproj b)) $ do
           markDisplayNeeded (blid b)
           when (hpDelta < 0) $ do
             sUIOptions <- getsSession sUIOptions
             currentWarning <-
               getsState $ checkWarningHP sUIOptions aid (bhp b)
             when currentWarning $ do
               previousWarning <-
                 getsState $ checkWarningHP sUIOptions aid (bhp b - hpDelta)
               unless previousWarning $
                 aidVerbMU0 MsgDeathThreat aid
                            "be down to a dangerous health level"
  UpdRefillCalm _ 0 -> return ()
  UpdRefillCalm aid calmDelta -> do
    side <- getsClient sside
    b <- getsState $ getActorBody aid
    when (bfid b == side && not (bproj b)) $ do
      if | calmDelta > 0 ->  -- regeneration or effect
           markDisplayNeeded (blid b)
         | calmDelta == minusM1 -> do
           fact <- getsState $ (EM.! side) . sfactionD
           s <- getState
           let closeFoe (!p, aid2) =  -- mimics isHeardFoe
                 let b2 = getActorBody aid2 s
                 in inline chessDist p (bpos b) <= 3
                    && not (actorWaitsOrSleeps b2)  -- uncommon
                    && inline isFoe side fact (bfid b2)  -- costly
               anyCloseFoes = any closeFoe $ EM.assocs $ lbig
                                           $ sdungeon s EM.! blid b
           unless anyCloseFoes $ do  -- obvious where the feeling comes from
             duplicated <- aidVerbDuplicateMU MsgHeardClose aid "hear something"
             unless duplicated stopPlayBack
         | otherwise ->  -- low deltas from hits; displayed elsewhere
           return ()
      when (calmDelta < 0) $ do
        sUIOptions <- getsSession sUIOptions
        currentWarning <-
          getsState $ checkWarningCalm sUIOptions aid (bcalm b)
        when currentWarning $ do
          previousWarning <-
            getsState $ checkWarningCalm sUIOptions aid (bcalm b - calmDelta)
          unless previousWarning $
            -- This messages is not shown if impression happens after
            -- Calm is low enough. However, this is rare and HUD shows the red.
            aidVerbMU0 MsgDeathThreat aid
                       "have grown agitated and impressed enough to be in danger of defecting"
  UpdTrajectory _ _ mt ->  -- if projectile dies just after, force one frame
    when (maybe True (null . fst) mt) pushFrame
  -- Change faction attributes.
  UpdQuitFaction fid _ toSt manalytics -> quitFactionUI fid toSt manalytics
  UpdSpotStashFaction verbose fid lid pos -> do
    when verbose $ do
      side <- getsClient sside
      if fid == side then
        msgAdd MsgDiplomacy
               "You set up the shared inventory stash of your team."
      else do
        fact <- getsState $ (EM.! fid) . sfactionD
        let fidName = MU.Text $ gname fact
        msgAdd MsgDiplomacy $
          makeSentence [ "you have found the current"
                       , MU.WownW fidName "hoard location" ]
    animate lid $ actorX pos
  UpdLoseStashFaction verbose fid lid pos -> do
    when verbose $ do
      side <- getsClient sside
      if fid == side then
        msgAdd MsgDiplomacy "You've lost access to your shared inventory stash!"
      else do
        fact <- getsState $ (EM.! fid) . sfactionD
        let fidName = MU.Text $ gname fact
        msgAdd MsgDiplomacy $
          makeSentence [fidName, "no longer control their hoard"]
    animate lid $ vanish pos
  UpdLeadFaction fid (Just source) (Just target) -> do
    fact <- getsState $ (EM.! fid) . sfactionD
    lidV <- viewedLevelUI
    when (isAIFact fact) $ markDisplayNeeded lidV
    -- This faction can't run with multiple actors, so this is not
    -- a leader change while running, but rather server changing
    -- their leader, which the player should be alerted to.
    when (noRunWithMulti fact) stopPlayBack
    actorD <- getsState sactorD
    case EM.lookup source actorD of
      Just sb | bhp sb <= 0 -> assert (not $ bproj sb) $ do
        -- Regardless who the leader is, give proper names here, not 'you'.
        sbUI <- getsSession $ getActorUI source
        tbUI <- getsSession $ getActorUI target
        let subject = partActor tbUI
            object  = partActor sbUI
        msgAdd MsgLeader $
          makeSentence [ MU.SubjectVerbSg subject "take command"
                       , "from", object ]
      _ -> return ()
    lookAtMove target
  UpdLeadFaction _ Nothing (Just target) -> lookAtMove target
  UpdLeadFaction{} -> return ()
  UpdDiplFaction fid1 fid2 _ toDipl -> do
    name1 <- getsState $ gname . (EM.! fid1) . sfactionD
    name2 <- getsState $ gname . (EM.! fid2) . sfactionD
    let showDipl Unknown = "unknown to each other"
        showDipl Neutral = "in neutral diplomatic relations"
        showDipl Alliance = "allied"
        showDipl War = "at war"
    msgAdd MsgDiplomacy $
      name1 <+> "and" <+> name2 <+> "are now" <+> showDipl toDipl <> "."
  UpdDoctrineFaction{} -> return ()
  UpdAutoFaction fid b -> do
    side <- getsClient sside
    lidV <- viewedLevelUI
    markDisplayNeeded lidV
    when (fid == side) $ do
      unless b $ addPressedControlEsc  -- sets @swasAutomated@, enters main menu
      setFrontAutoYes b  -- now can stop auto-accepting prompts
  UpdRecordKill{} -> return ()
  -- Alter map.
  UpdAlterTile lid p fromTile toTile -> do
    markDisplayNeeded lid
    COps{cotile} <- getsState scops
    let feats = TK.tfeature $ okind cotile fromTile
        toAlter feat =
          case feat of
            TK.OpenTo tgroup -> Just tgroup
            TK.CloseTo tgroup -> Just tgroup
            TK.ChangeTo tgroup -> Just tgroup
            _ -> Nothing
        groupsToAlterTo = mapMaybe toAlter feats
        freq = map fst $ filter (\(_, q) -> q > 0)
               $ TK.tfreq $ okind cotile toTile
    when (null $ intersect freq groupsToAlterTo) $ do
      -- Player notices @fromTile can't be altered into @toTIle@,
      -- which is uncanny, so we produce a message.
      -- This happens when the player missed an earlier search of the tile
      -- performed by another faction.
      let subject = ""  -- a hack, because we don't handle adverbs well
          verb = "turn into"
          msg = makeSentence
            [ "the", MU.Text $ TK.tname $ okind cotile fromTile
            , "at position", MU.Text $ tshow p
            , "suddenly"  -- adverb
            , MU.SubjectVerbSg subject verb
            , MU.AW $ MU.Text $ TK.tname $ okind cotile toTile ]
      msgAdd MsgTileDisco msg
  UpdAlterExplorable lid _ -> markDisplayNeeded lid
  UpdAlterGold{} -> return ()  -- not displayed on HUD
  UpdSearchTile aid _p toTile -> do
    COps{cotile} <- getsState scops
    subject <- partActorLeader aid
    let fromTile = fromMaybe (error $ show toTile) $ Tile.hideAs cotile toTile
        subject2 = MU.Text $ TK.tname $ okind cotile fromTile
        object = MU.Text $ TK.tname $ okind cotile toTile
    let msg = makeSentence [ MU.SubjectVerbSg subject "reveal"
                           , "that the"
                           , MU.SubjectVerbSg subject2 "be"
                           , MU.AW object ]
    unless (subject2 == object) $ msgAdd MsgTileDisco msg
  UpdHideTile{} -> return ()
  UpdSpotTile{} -> return ()
  UpdLoseTile{} -> return ()
  UpdSpotEntry{} -> return ()
  UpdLoseEntry{} -> return ()
  UpdAlterSmell{} -> return ()
  UpdSpotSmell{} -> return ()
  UpdLoseSmell{} -> return ()
  -- Assorted.
  UpdTimeItem{} -> return ()
  UpdAgeGame{} -> do
    sdisplayNeeded <- getsSession sdisplayNeeded
    time <- getsState stime
    let clipN = time `timeFit` timeClip
        clipMod = clipN `mod` clipsInTurn
        ping = clipMod == 0
    when (sdisplayNeeded || ping) pushFrame
  UpdUnAgeGame{} -> return ()
  UpdDiscover c iid _ _ -> discover c iid
  UpdCover{} -> return ()  -- don't spam when doing undo
  UpdDiscoverKind{} -> return ()  -- don't spam when server tweaks stuff
  UpdCoverKind{} -> return ()  -- don't spam when doing undo
  UpdDiscoverAspect{} -> return ()  -- don't spam when server tweaks stuff
  UpdCoverAspect{} -> return ()  -- don't spam when doing undo
  UpdDiscoverServer{} -> error "server command leaked to client"
  UpdCoverServer{} -> error "server command leaked to client"
  UpdPerception{} -> return ()
  UpdRestart fid _ _ _ _ _ -> do
    COps{cocave, corule} <- getsState scops
    sstart <- getsSession sstart
    when (sstart == 0) resetSessionStart
    history <- getsSession shistory
    if lengthHistory history == 0 then do
      let title = T.pack $ rtitle corule
      msgAdd MsgAdmin $ "Welcome to" <+> title <> "!"
      -- Generate initial history. Only for UI clients.
      shistory <- defaultHistory
      modifySession $ \sess -> sess {shistory}
    else
      recordHistory
    lid <- getArenaUI
    lvl <- getLevel lid
    mode <- getGameMode
    curChal <- getsClient scurChal
    fact <- getsState $ (EM.! fid) . sfactionD
    let loneMode = case ginitial fact of
          [] -> True
          [(_, 1, _)] -> True
          _ -> False
    recordHistory
    msgAdd MsgAdmin "----------------------------------------------------------"
    recordHistory
    msgAdd MsgWarning $ "New game started in" <+> mname mode <+> "mode."
    msgAdd MsgAdmin $ mdesc mode
    let desc = cdesc $ okind cocave $ lkind lvl
    unless (T.null desc) $ do
      msgAdd0 MsgFocus "You take in your surroundings."
      msgAdd0 MsgLandscape desc
    -- We can fool the player only once (per scenario), but let's not do it
    -- in the same way each time. TODO: PCG
    blurb <- rndToActionForget $ oneOf
      [ "You think you saw movement."
      , "Something catches your peripherial vision."
      , "You think you felt a tremor under your feet."
      , "A whiff of chilly air passes around you."
      , "You notice a draft just when it dies down."
      , "The ground nearby is stained along some faint lines."
      , "Scarce black motes slowly settle on the ground."
      , "The ground in the immediate area is empty, as if just swiped."
      ]
    msgAdd MsgWarning blurb
    when (cwolf curChal && not loneMode) $
      msgAdd MsgWarning "Being a lone wolf, you begin without companions."
    when (lengthHistory history > 1) $ fadeOutOrIn False
    setFrontAutoYes $ isAIFact fact
    when (isAIFact fact) $ do
      -- Prod the frontend to flush frames and start showing them continuously.
      slides <- reportToSlideshow []
      void $ getConfirms ColorFull [K.spaceKM, K.escKM] slides
    -- Forget the furious keypresses when dying in the previous game.
    resetPressedKeys
  UpdRestartServer{} -> return ()
  UpdResume fid _ -> do
    COps{cocave} <- getsState scops
    resetSessionStart
    fact <- getsState $ (EM.! fid) . sfactionD
    setFrontAutoYes $ isAIFact fact
    unless (isAIFact fact) $ do
      lid <- getArenaUI
      lvl <- getLevel lid
      mode <- getGameMode
      msgAdd MsgAlert $ "Continuing" <+> mname mode <> "."
      msgAdd MsgPrompt $ mdesc mode
      let desc = cdesc $ okind cocave $ lkind lvl
      unless (T.null desc) $ do
        msgAdd MsgPromptFocus "\nYou remember your surroundings."
        msgAdd MsgPrompt desc
      displayMore ColorFull "\nAre you up for the challenge?"
      promptAdd0 "Prove yourself!"
  UpdResumeServer{} -> return ()
  UpdKillExit{} -> frontendShutdown
  UpdWriteSave -> msgAdd MsgSpam "Saving backup."
  UpdHearFid _ hearMsg -> do
    mleader <- getsClient sleader
    case mleader of
      Just{} -> return ()  -- will display stuff when leader moves
      Nothing -> do
        lidV <- viewedLevelUI
        markDisplayNeeded lidV
        recordHistory
    msg <- ppHearMsg hearMsg
    msgAdd MsgHeard msg

updateItemSlot :: MonadClientUI m => Container -> ItemId -> m ()
updateItemSlot c iid = do
  arItem <- getsState $ aspectRecordFromIid iid
  ItemSlots itemSlots <- getsSession sslots
  let slore = IA.loreFromContainer arItem c
      lSlots = itemSlots EM.! slore
  case lookup iid $ map swap $ EM.assocs lSlots of
    Nothing -> do
      let l = assignSlot lSlots
          f = EM.insert l iid
          newSlots = ItemSlots $ EM.adjust f slore itemSlots
      modifySession $ \sess -> sess {sslots = newSlots}
    Just _l -> return ()  -- slot already assigned

markDisplayNeeded :: MonadClientUI m => LevelId -> m ()
markDisplayNeeded lid = do
  lidV <- viewedLevelUI
  when (lidV == lid) $ modifySession $ \sess -> sess {sdisplayNeeded = True}

lookAtMove :: MonadClientUI m => ActorId -> m ()
lookAtMove aid = do
  mleader <- getsClient sleader
  body <- getsState $ getActorBody aid
  side <- getsClient sside
  aimMode <- getsSession saimMode
  when (not (bproj body)
        && bfid body == side
        && isNothing aimMode) $ do  -- aiming does a more extensive look
    itemsBlurb <- lookAtItems True (bpos body) aid
    let msgClass = if Just aid == mleader then MsgAtFeetMajor else MsgAtFeet
    msgAdd msgClass itemsBlurb
  fact <- getsState $ (EM.! bfid body) . sfactionD
  adjBigAssocs <- getsState $ adjacentBigAssocs body
  adjProjAssocs <- getsState $ adjacentProjAssocs body
  if not (bproj body) && bfid body == side then do
    let foe (_, b2) = isFoe (bfid body) fact (bfid b2)
        adjFoes = filter foe $ adjBigAssocs ++ adjProjAssocs
    unless (null adjFoes) stopPlayBack
  else when (isFoe (bfid body) fact side) $ do
    let our (_, b2) = bfid b2 == side
        adjOur = filter our adjBigAssocs
    unless (null adjOur) stopPlayBack

aidVerbMU :: MonadClientUI m => MsgClass -> ActorId -> MU.Part -> m ()
aidVerbMU msgClass aid verb = do
  subject <- partActorLeader aid
  msgAdd msgClass $ makeSentence [MU.SubjectVerbSg subject verb]

aidVerbMU0 :: MonadClientUI m => MsgClass -> ActorId -> MU.Part -> m ()
aidVerbMU0 msgClass aid verb = do
  subject <- partActorLeader aid
  msgAdd0 msgClass $ makeSentence [MU.SubjectVerbSg subject verb]

aidVerbDuplicateMU :: MonadClientUI m
                   => MsgClass -> ActorId -> MU.Part -> m Bool
aidVerbDuplicateMU msgClass aid verb = do
  subject <- partActorLeader aid
  msgAddDuplicate (makeSentence [MU.SubjectVerbSg subject verb]) msgClass 1

itemVerbMU :: MonadClientUI m
           => MsgClass -> ItemId -> ItemQuant -> MU.Part -> Container -> m ()
itemVerbMU msgClass iid kit@(k, _) verb c = assert (k > 0) $ do
  lid <- getsState $ lidFromC c
  localTime <- getsState $ getLocalTime lid
  itemFull <- getsState $ itemToFull iid
  side <- getsClient sside
  factionD <- getsState sfactionD
  let arItem = aspectRecordFull itemFull
      subject = partItemWs side factionD k localTime itemFull kit
      msg | k > 1 && not (IA.checkFlag Ability.Condition arItem) =
              makeSentence [MU.SubjectVerb MU.PlEtc MU.Yes subject verb]
          | otherwise = makeSentence [MU.SubjectVerbSg subject verb]
  msgAdd msgClass msg

itemAidVerbMU :: MonadClientUI m
              => MsgClass -> ActorId -> MU.Part
              -> ItemId -> Either (Maybe Int) Int
              -> m ()
itemAidVerbMU msgClass aid verb iid ek = do
  body <- getsState $ getActorBody aid
  side <- getsClient sside
  factionD <- getsState sfactionD
  let lid = blid body
      fakeKit = (1, [])
  localTime <- getsState $ getLocalTime lid
  subject <- partActorLeader aid
  -- The item may no longer be in @c@, but it was.
  itemFull <- getsState $ itemToFull iid
  let object = case ek of
        Left (Just n) -> partItemWs side factionD n localTime itemFull fakeKit
        Left Nothing -> let (name, powers) =
                              partItem side factionD localTime itemFull fakeKit
                        in MU.Phrase [name, powers]
        Right n -> let (name1, powers) =
                         partItemShort side factionD localTime itemFull fakeKit
                   in MU.Phrase ["the", MU.Car1Ws n name1, powers]
      msg = makeSentence [MU.SubjectVerbSg subject verb, object]
  msgAdd msgClass msg

manyItemsAidVerbMU :: MonadClientUI m
                   => MsgClass -> ActorId -> MU.Part
                   -> ItemBag -> (Int -> Either (Maybe Int) Int)
                   -> m ()
manyItemsAidVerbMU msgClass aid verb bag ekf = do
  body <- getsState $ getActorBody aid
  side <- getsClient sside
  factionD <- getsState sfactionD
  let lid = blid body
      fakeKit = (1, [])
  localTime <- getsState $ getLocalTime lid
  subject <- partActorLeader aid
  -- The item may no longer be in @c@, but it was.
  itemToF <- getsState $ flip itemToFull
  let object (iid, (k, _)) =
        let itemFull = itemToF iid
        in case ekf k of
          Left (Just n) -> partItemWs side factionD n localTime itemFull fakeKit
          Left Nothing -> let (name, powers) = partItem side factionD localTime
                                                        itemFull fakeKit
                          in MU.Phrase [name, powers]
          Right n -> let (name1, powers) = partItemShort side factionD localTime
                                                         itemFull fakeKit
                     in MU.Phrase ["the", MU.Car1Ws n name1, powers]
      msg = makeSentence [ MU.SubjectVerbSg subject verb
                         , MU.WWandW $ map object $ EM.assocs bag]
  msgAdd msgClass msg

createActorUI :: MonadClientUI m => Bool -> ActorId -> Actor -> m ()
createActorUI born aid body = do
  side <- getsClient sside
  when (bfid body == side && not (bproj body)) $ do
    let upd = ES.insert aid
    modifySession $ \sess -> sess {sselected = upd $ sselected sess}
  factionD <- getsState sfactionD
  let fact = factionD EM.! bfid body
  localTime <- getsState $ getLocalTime $ blid body
  itemFull@ItemFull{itemBase, itemKind} <- getsState $ itemToFull (btrunk body)
  actorUI <- getsSession sactorUI
  let arItem = aspectRecordFull itemFull
  unless (aid `EM.member` actorUI) $ do
    UIOptions{uHeroNames} <- getsSession sUIOptions
    let baseColor = flavourToColor $ jflavour itemBase
        basePronoun | not (bproj body)
                      && IK.isymbol itemKind == '@'
                      && fhasGender (gplayer fact) = "he"
                    | otherwise = "it"
        nameFromNumber fn k = if k == 0
                              then makePhrase [MU.Ws $ MU.Text fn, "Captain"]
                              else fn <+> tshow k
        heroNamePronoun k =
          if gcolor fact /= Color.BrWhite
          then (nameFromNumber (fname $ gplayer fact) k, "he")
          else fromMaybe (nameFromNumber (fname $ gplayer fact) k, "he")
               $ lookup k uHeroNames
    (n, bsymbol) <-
      if | bproj body -> return (0, if IA.checkFlag Ability.Blast arItem
                                    then IK.isymbol itemKind
                                    else '*')
         | baseColor /= Color.BrWhite -> return (0, IK.isymbol itemKind)
         | otherwise -> do
           let hasNameK k bUI = bname bUI == fst (heroNamePronoun k)
                                && bcolor bUI == gcolor fact
               findHeroK k = isJust $ find (hasNameK k) (EM.elems actorUI)
               mhs = map findHeroK [0..]
               n = fromMaybe (error $ show mhs) $ elemIndex False mhs
           return (n, if 0 < n && n < 10 then Char.intToDigit n else '@')
    let (object1, object2) = partItemShortest (bfid body) factionD localTime
                                              itemFull (1, [])
        (bname, bpronoun) =
          if | bproj body ->
               let adj = case btrajectory body of
                     Just (tra, _) | length tra < 5 -> "falling"
                     _ -> "flying"
               in (makePhrase [adj, object1, object2], basePronoun)
             | baseColor /= Color.BrWhite ->
               let name = makePhrase [object1, object2]
               in ( if IA.checkFlag Ability.Unique arItem
                    then makePhrase [MU.Capitalize $ MU.Text $ "the" <+> name]
                    else name
                  , basePronoun )
             | otherwise -> heroNamePronoun n
        bcolor | bproj body = if IA.checkFlag Ability.Blast arItem
                              then baseColor
                              else Color.BrWhite
               | baseColor == Color.BrWhite = gcolor fact
               | otherwise = baseColor
        bUI = ActorUI{..}
    modifySession $ \sess ->
      sess {sactorUI = EM.insert aid bUI actorUI}
  let verb = MU.Text $
        if born
        then if bfid body == side then "join you" else "appear suddenly"
        else "be spotted"
  mapM_ (\(iid, store) -> do
           let c = if not (bproj body) && iid == btrunk body
                   then CTrunk (bfid body) (blid body) (bpos body)
                   else CActor aid store
           updateItemSlot c iid
           recordItemLid iid c)
        ((btrunk body, CEqp)  -- store will be overwritten, unless projectile
         : filter ((/= btrunk body) . fst) (getCarriedIidCStore body))
  -- Don't spam if the actor was already visible (but, e.g., on a tile that is
  -- invisible this turn (in that case move is broken down to lose+spot)
  -- or on a distant tile, via teleport while the observer teleported, too).
  lastLost <- getsSession slastLost
  if | EM.null actorUI && bfid body == side ->
       return ()  -- don't speak about yourself in 3rd person
     | born && bproj body -> pushFrame  -- make sure first position displayed
     | ES.member aid lastLost || bproj body -> markDisplayNeeded (blid body)
     | otherwise -> do
       aidVerbMU MsgActorSpot aid verb
       animate (blid body) $ actorX (bpos body)
  when (bfid body /= side) $ do
    when (not (bproj body) && isFoe (bfid body) fact side) $ do
      -- Aim even if nobody can shoot at the enemy. Let's home in on him
      -- and then we can aim or melee. We set permit to False, because it's
      -- technically very hard to check aimability here, because we are
      -- in-between turns and, e.g., leader's move has not yet been taken
      -- into account.
      modifySession $ \sess -> sess {sxhair = Just $ TEnemy aid}
      foes <- getsState $ foeRegularList side (blid body)
      unless (ES.member aid lastLost || length foes > 1) $
        msgAdd0 MsgFirstEnemySpot "You are not alone!"
    stopPlayBack

destroyActorUI :: MonadClientUI m => Bool -> ActorId -> Actor -> m ()
destroyActorUI destroy aid b = do
  trunk <- getsState $ getItemBody $ btrunk b
  let baseColor = flavourToColor $ jflavour trunk
  unless (baseColor == Color.BrWhite) $  -- keep setup for heroes, etc.
    modifySession $ \sess -> sess {sactorUI = EM.delete aid $ sactorUI sess}
  let affect tgt = case tgt of
        Just (TEnemy a) | a == aid -> Just $
          if destroy then
            -- If *really* nothing more interesting, the actor will
            -- go to last known location to perhaps find other foes.
            TPoint TKnown (blid b) (bpos b)
          else
            -- If enemy only hides (or we stepped behind obstacle) find him.
            TPoint (TEnemyPos a) (blid b) (bpos b)
        Just (TNonEnemy a) | a == aid -> Just $ TPoint TKnown (blid b) (bpos b)
        _ -> tgt
  modifySession $ \sess -> sess {sxhair = affect $ sxhair sess}
  unless (bproj b) $
    modifySession $ \sess -> sess {slastLost = ES.insert aid $ slastLost sess}
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let gameOver = isJust $ gquit fact  -- we are the UI faction, so we determine
  unless gameOver $ do
    when (bfid b == side && not (bproj b)) $ do
      stopPlayBack
      let upd = ES.delete aid
      modifySession $ \sess -> sess {sselected = upd $ sselected sess}
      when destroy $ do
        mleader <- getsClient sleader
        when (isJust mleader)
          -- This is especially handy when the dead actor was a leader
          -- on a different level than the new one:
          clearAimMode
    -- If pushed, animate spotting again, to draw attention to pushing.
    markDisplayNeeded (blid b)

spotItem :: MonadClientUI m
         => Bool -> ItemId -> ItemQuant -> Container -> m ()
spotItem verbose iid kit@(k, _) c = do
  -- This is due to a move, or similar, which will be displayed,
  -- so no extra @markDisplayNeeded@ needed here and in similar places.
  recordItemLid iid c
  ItemSlots itemSlots <- getsSession sslots
  arItem <- getsState $ aspectRecordFromIid iid
  let slore = IA.loreFromContainer arItem c
  case lookup iid $ map swap $ EM.assocs $ itemSlots EM.! slore of
    Nothing -> do  -- never seen or would have a slot
      updateItemSlot c iid
      case c of
        CFloor lid p -> do
          sxhairOld <- getsSession sxhair
          case sxhairOld of
            Just TEnemy{} -> return ()  -- probably too important to overwrite
            Just (TPoint TEnemyPos{} _ _) -> return ()
            _ -> do
              -- Don't steal xhair if it's only an item on another level.
              -- For enemies, OTOH, capture xhair to alarm player.
              lidV <- viewedLevelUI
              when (lid == lidV) $ do
                bag <- getsState $ getFloorBag lid p
                modifySession $ \sess ->
                  sess {sxhair = Just $ TPoint (TItem bag) lidV p}
          itemVerbMU MsgItemMove iid kit "be located" c
        _ -> return ()
    _ -> return ()  -- this item or another with the same @iid@
                    -- seen already (has a slot assigned), so old news
  when verbose $ case c of
    CActor aid store -> do
      let verb = MU.Text $ verbCStore store
      b <- getsState $ getActorBody aid
      fact <- getsState $ (EM.! bfid b) . sfactionD
      let underAI = isAIFact fact
      mleader <- getsClient sleader
      if Just aid == mleader && not underAI then
        itemAidVerbMU MsgItemMove aid verb iid (Right k)
      else when (not (bproj b) && bhp b > 0) $  -- don't announce death drops
        itemAidVerbMU MsgItemMove aid verb iid (Left $ Just k)
    _ -> return ()

recordItemLid :: MonadClientUI m => ItemId -> Container -> m ()
recordItemLid iid c = do
  mjlid <- getsSession $ EM.lookup iid . sitemUI
  when (isNothing mjlid) $ do
    lid <- getsState $ lidFromC c
    modifySession $ \sess ->
      sess {sitemUI = EM.insert iid lid $ sitemUI sess}

moveActor :: MonadClientUI m => ActorId -> Point -> Point -> m ()
moveActor aid source target = do
  -- If source and target tile distant, assume it's a teleportation
  -- and display an animation. Note: jumps and pushes go through all
  -- intervening tiles, so won't be considered. Note: if source or target
  -- not seen, the (half of the) animation would be boring, just a delay,
  -- not really showing a transition, so we skip it (via 'breakUpdAtomic').
  -- The message about teleportation is sometimes shown anyway, just as the X.
  body <- getsState $ getActorBody aid
  if adjacent source target
  then markDisplayNeeded (blid body)
  else do
    let ps = (source, target)
    animate (blid body) $ teleport ps
  lookAtMove aid

displaceActorUI :: MonadClientUI m => ActorId -> ActorId -> m ()
displaceActorUI source target = do
  mleader <- getsClient sleader
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  spart <- partActorLeader source
  tpart <- partActorLeader target
  let msgClass = if mleader `elem` map Just [source, target]
                 then MsgAction  -- to avoid run after displace; configurable
                 else MsgActionMinor
      msg = makeSentence [MU.SubjectVerbSg spart "displace", tpart]
  msgAdd msgClass msg
  when (bfid sb /= bfid tb) $ do
    lookAtMove source
    lookAtMove target
  side <- getsClient sside
  -- Ours involved, but definitely not requested by player via UI.
  when (side `elem` [bfid sb, bfid tb] && mleader /= Just source) stopPlayBack
  let ps = (bpos tb, bpos sb)
  animate (blid sb) $ swapPlaces ps

-- @UpdMoveItem@ is relatively rare (except within the player's faction),
-- but it ensure that even if only one of the stores is visible
-- (e.g., stash floor is not or actor posision is not), some messages
-- will be printed (via verbose @UpdLoseItem@).
moveItemUI :: MonadClientUI m
           => ItemId -> Int -> ActorId -> CStore -> CStore
           -> m ()
moveItemUI iid k aid cstore1 cstore2 = do
  let verb = MU.Text $ verbCStore cstore2
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  let underAI = isAIFact fact
  mleader <- getsClient sleader
  ItemSlots itemSlots <- getsSession sslots
  case lookup iid $ map swap $ EM.assocs $ itemSlots EM.! SItem of
    Just _l ->
      -- So far organs can't be put into backpack, so no need to call
      -- @updateItemSlot@ to add or reassign lore category.
      if cstore1 == CGround && Just aid == mleader && not underAI then
        itemAidVerbMU MsgItemMove aid verb iid (Right k)
      else when (not (bproj b) && bhp b > 0) $  -- don't announce death drops
        itemAidVerbMU MsgItemMove aid verb iid (Left $ Just k)
    Nothing -> error $
      "" `showFailure` (iid, k, aid, cstore1, cstore2)

quitFactionUI :: MonadClientUI m
              => FactionId -> Maybe Status
              -> Maybe (FactionAnalytics, GenerationAnalytics)
              -> m ()
quitFactionUI fid toSt manalytics = do
  ClientOptions{sexposeItems} <- getsClient soptions
  fact <- getsState $ (EM.! fid) . sfactionD
  let fidName = MU.Text $ gname fact
      person = if fhasGender $ gplayer fact then MU.PlEtc else MU.Sg3rd
      horror = isHorrorFact fact
      camping = maybe True ((== Camping) . stOutcome) toSt
  side <- getsClient sside
  when (fid == side && not camping) $ do
    tellGameClipPS
    resetGameStart
  mode <- getGameMode
  allNframes <- getsSession sallNframes
  let startingPart = case toSt of
        _ | horror -> Nothing  -- Ignore summoned actors' factions.
        Just Status{stOutcome=Killed} -> Just "be eliminated"
        Just Status{stOutcome=Defeated} -> Just "be decisively defeated"
        Just Status{stOutcome=Camping} -> Just "order save and exit"
        Just Status{stOutcome=Conquer} -> Just "vanquish all foes"
        Just Status{stOutcome=Escape} -> Just "achieve victory"
        Just Status{stOutcome=Restart, stNewGame=Just gn} ->
          Just $ MU.Text $ "order mission restart in"
                           <+> fromGroupName gn <+> "mode"
        Just Status{stOutcome=Restart, stNewGame=Nothing} ->
          error $ "" `showFailure` (fid, toSt)
        Nothing -> Nothing  -- server wipes out Camping for savefile
      middlePart = case toSt of
        _ | fid /= side -> Nothing
        Just Status{stOutcome} -> lookup stOutcome $ mendMsg mode
        Nothing -> Nothing
      partingPart = case toSt of
        _ | fid /= side || allNframes == -1 -> Nothing
        Just Status{stOutcome} -> lookup stOutcome genericEndMessages
        Nothing -> Nothing
  case startingPart of
    Nothing -> return ()
    Just sp ->
      let blurb = makeSentence [MU.SubjectVerb person MU.Yes fidName sp]
      in if fid == side
         then msgLnAdd MsgOutcome blurb
         else msgAdd MsgDiplomacy blurb
  case (toSt, partingPart) of
    (Just status, Just pp) -> do
      isNoConfirms <- isNoConfirmsGame
      go <- if isNoConfirms
            then return False
            else displaySpaceEsc ColorFull ""
      recordHistory
        -- we are going to exit or restart, so record and clear, but only once
      (itemBag, total) <- getsState $ calculateTotal side
      when go $ do
        case middlePart of
          Nothing -> return ()
          Just sp1 -> do
            factionD <- getsState sfactionD
            itemToF <- getsState $ flip itemToFull
            let getTrunkFull (_, b) = itemToF $ btrunk b
            ourTrunks <- getsState $ map getTrunkFull
                                     . fidActorNotProjGlobalAssocs side
            let smartFaction fact2 = fleaderMode (gplayer fact2) /= LeaderNull
                canBeSmart = any (smartFaction . snd)
                canBeOurFaction = any (\(fid2, _) -> fid2 == side)
                smartEnemy trunkFull =
                  let possible =
                        possibleActorFactions (itemKind trunkFull) factionD
                  in not (canBeOurFaction possible) && canBeSmart possible
                smartEnemyOurs = filter smartEnemy ourTrunks
                uniqueActor trunkFull = IA.checkFlag Ability.Unique
                                        $ aspectRecordFull trunkFull
                smartUniqueEnemyCaptured = any uniqueActor smartEnemyOurs
                smartEnemyCaptured = not $ null smartEnemyOurs
                sp2 | smartUniqueEnemyCaptured =
                  "\nOh, wait, who is this, towering behind your escaping crew? This changes everything. For everybody. Everywhere. Forever. Did you plan for this? What was exactly the idea and who decided to carry it through?"
                    | smartEnemyCaptured =
                  "\nOh, wait, who is this, hunched among your escaping crew? Suddenly, this makes your crazy story credible. Suddenly, the door of knowledge opens again. How will you play that move?"
                    | otherwise = ""
            msgAdd0 MsgPlot $ sp1 <> sp2
            void $ displaySpaceEsc ColorFull ""
        case manalytics of
          Nothing -> return ()
          Just (factionAn, generationAn) ->
            cycleLore []
              [ displayGameOverLoot (itemBag, total) generationAn
              , displayGameOverAnalytics factionAn generationAn
              , displayGameOverLore SEmbed True generationAn
              , displayGameOverLore SOrgan True generationAn
              , displayGameOverLore SCondition sexposeItems generationAn
              , displayGameOverLore SBlast True generationAn ]
      unless isNoConfirms $ do
        -- Show score for any UI client after any kind of game exit,
        -- even though it's saved only for human UI clients at game over
        -- (that is not a noConfirms or benchmark game).
        scoreSlides <- scoreToSlideshow total status
        void $ getConfirms ColorFull [K.spaceKM, K.escKM] scoreSlides
      -- The last prompt stays onscreen during shutdown, etc.
      when (not isNoConfirms || camping) $
        void $ displaySpaceEsc ColorFull pp
    _ -> return ()

displayGameOverLoot :: MonadClientUI m
                    => (ItemBag, Int) -> GenerationAnalytics -> m K.KM
displayGameOverLoot (heldBag, total) generationAn = do
  ClientOptions{sexposeItems} <- getsClient soptions
  COps{coitem} <- getsState scops
  ItemSlots itemSlots <- getsSession sslots
  -- We assume "gold grain", not "grain" with label "of gold":
  let currencyName = IK.iname $ okind coitem $ ouniqGroup coitem "currency"
      lSlotsRaw = EM.filter (`EM.member` heldBag) $ itemSlots EM.! SItem
      generationItem = generationAn EM.! SItem
      (itemBag, lSlots) =
        if sexposeItems
        then let generationBag = EM.map (\k -> (-k, [])) generationItem
                 bag = heldBag `EM.union` generationBag
                 slots = EM.fromDistinctAscList $ zip allSlots $ EM.keys bag
             in (bag, slots)
        else (heldBag, lSlotsRaw)
      promptFun iid itemFull2 k =
        let worth = itemPrice 1 $ itemKind itemFull2
            lootMsg = if worth == 0 then "" else
              let pile = if k == 1 then "exemplar" else "hoard"
              in makeSentence $
                   ["this treasure", pile, "is worth"]
                   ++ (if k > 1 then [ MU.Cardinal k, "times"] else [])
                   ++ [MU.CarWs worth $ MU.Text currencyName]
            holdsMsg =
              let n = generationItem EM.! iid
              in if | max 0 k == 1 && n == 1 ->
                      "You keep the only specimen extant:"
                    | max 0 k == 0 && n == 1 ->
                      "You don't have the only hypothesized specimen:"
                    | max 0 k == 0 && n == 0 ->
                      "No such specimen was recorded:"
                    | otherwise -> makePhrase [ "You hold"
                                              , MU.CardinalAWs (max 0 k) "piece"
                                              , "out of"
                                              , MU.Car n
                                              , "scattered:" ]
        in lootMsg <+> holdsMsg
  dungeonTotal <- getsState sgold
  let promptGold = spoilsBlurb currencyName total dungeonTotal
      -- Total number of items is meaningless in the presence of so much junk.
      prompt = promptGold
               <+> (if sexposeItems
                    then "Non-positive count means none held but this many generated."
                    else "")
      examItem = displayItemLore itemBag 0 promptFun
  viewLoreItems "GameOverLoot" lSlots itemBag prompt examItem

displayGameOverAnalytics :: MonadClientUI m
                         => FactionAnalytics -> GenerationAnalytics
                         -> m K.KM
displayGameOverAnalytics factionAn generationAn = do
  ClientOptions{sexposeActors} <- getsClient soptions
  side <- getsClient sside
  ItemSlots itemSlots <- getsSession sslots
  let ourAn = akillCounts
              $ EM.findWithDefault emptyAnalytics side factionAn
      foesAn = EM.unionsWith (+)
               $ concatMap EM.elems $ catMaybes
               $ map (`EM.lookup` ourAn) [KillKineticMelee .. KillOtherPush]
      trunkBagRaw = EM.map (, []) foesAn
      lSlotsRaw = EM.filter (`EM.member` trunkBagRaw) $ itemSlots EM.! STrunk
      killedBag = EM.fromList $ map (\iid -> (iid, trunkBagRaw EM.! iid))
                                    (EM.elems lSlotsRaw)
      generationTrunk = generationAn EM.! STrunk
      (trunkBag, lSlots) =
        if sexposeActors
        then let generationBag = EM.map (\k -> (-k, [])) generationTrunk
                 bag = killedBag `EM.union` generationBag
                 slots = EM.fromDistinctAscList $ zip allSlots $ EM.keys bag
             in (bag, slots)
        else (killedBag, lSlotsRaw)
      total = sum $ filter (> 0) $ map fst $ EM.elems trunkBag
      promptFun :: ItemId -> ItemFull-> Int -> Text
      promptFun iid _ k =
        let n = generationTrunk EM.! iid
        in makePhrase [ "You recall the adversary, which you killed"
                      , MU.CarWs (max 0 k) "time", "out of"
                      , MU.CarWs n "individual", "reported:" ]
      prompt = makeSentence ["your team vanquished", MU.CarWs total "adversary"]
                 -- total reported would include our own, so not given
               <+> (if sexposeActors
                    then "Non-positive count means none killed but this many reported."
                    else "")
      examItem = displayItemLore trunkBag 0 promptFun
  viewLoreItems "GameOverAnalytics" lSlots trunkBag prompt examItem

displayGameOverLore :: MonadClientUI m
                    => SLore -> Bool -> GenerationAnalytics -> m K.KM
displayGameOverLore slore exposeCount generationAn = do
  let generationLore = generationAn EM.! slore
      generationBag = EM.map (\k -> (if exposeCount then k else 1, []))
                             generationLore
      total = sum $ map fst $ EM.elems generationBag
      slots = EM.fromDistinctAscList $ zip allSlots $ EM.keys generationBag
      promptFun :: ItemId -> ItemFull-> Int -> Text
      promptFun _ _ k =
        makeSentence
          [ "this", MU.Text (ppSLore slore), "manifested during your quest"
          , MU.CarWs k "time" ]
      prompt | total == 0 =
               makeSentence [ "you didn't experience any"
                            , MU.Ws $ MU.Text (headingSLore slore)
                            , "this time" ]
             | otherwise =
               makeSentence [ "you experienced the following variety of"
                            , MU.CarWs total $ MU.Text (headingSLore slore) ]
      examItem = displayItemLore generationBag 0 promptFun
  viewLoreItems ("GameOverLore" ++ show slore)
                slots generationBag prompt examItem

discover :: MonadClientUI m => Container -> ItemId -> m ()
discover c iid = do
  COps{coitem} <- getsState scops
  lid <- getsState $ lidFromC c
  globalTime <- getsState stime
  localTime <- getsState $ getLocalTime lid
  itemFull <- getsState $ itemToFull iid
  bag <- getsState $ getContainerBag c
  side <- getsClient sside
  factionD <- getsState sfactionD
  (noMsg, nameWhere) <- case c of
    CActor aidOwner storeOwner -> do
      bOwner <- getsState $ getActorBody aidOwner
      name <- if bproj bOwner
              then return []
              else ppContainerWownW partActorLeader True c
      let isOurOrgan = bfid bOwner == side && storeOwner == COrgan
            -- assume own faction organs known intuitively
      return (isOurOrgan, name)
    CTrunk _ _ p | p == originPoint -> return (True, [])
      -- the special reveal at game over, using fake @CTrunk@; don't spam
    _ -> return (False, [])
  let kit = EM.findWithDefault (1, []) iid bag  -- may be used up by that time
      knownName = partItemMediumAW side factionD localTime itemFull kit
      -- Make sure the two names in the message differ. We may end up with
      -- "the pair turns out to be a pair of trousers of destruction",
      -- but that's almost sensible. The fun of English.
      name = IK.iname $ okind coitem $ case jkind $ itemBase itemFull of
        IdentityObvious ik -> ik
        IdentityCovered _ix ik -> ik  -- fake kind; we talk about appearances
      flav = flavourToName $ jflavour $ itemBase itemFull
      unknownName = MU.Phrase $ [MU.Text flav, MU.Text name] ++ nameWhere
      msg = makeSentence
        ["the", MU.SubjectVerbSg unknownName "turn out to be", knownName]
  unless (noMsg || globalTime == timeZero) $  -- no spam about initial equipment
    msgAdd MsgItemDisco msg

ppHearMsg :: MonadClientUI m => HearMsg -> m Text
ppHearMsg hearMsg = case hearMsg of
  HearUpd local cmd -> do
    COps{coTileSpeedup} <- getsState scops
    let sound = case cmd of
          UpdDestroyActor{} -> "shriek"
          UpdCreateItem{} -> "clatter"
          UpdTrajectory{} -> "thud"  -- Something hits a non-walkable tile.
          UpdAlterTile _ _ _ toTile -> if Tile.isDoor coTileSpeedup toTile
                                       then "creaking sound"
                                       else "rumble"
          UpdAlterExplorable _ k -> if k > 0 then "grinding noise"
                                             else "fizzing noise"
          _ -> error $ "" `showFailure` cmd
        distant = if local then [] else ["distant"]
        msg = makeSentence [ "you hear"
                           , MU.AW $ MU.Phrase $ distant ++ [sound] ]
    return $! msg
  HearStrike ik -> do
    COps{coitem} <- getsState scops
    let verb = IK.iverbHit $ okind coitem ik
        msg = makeSentence [ "you hear something", MU.Text verb, "someone"]
    return $! msg
  HearSummon isProj grp p -> do
    let verb = if isProj then "something lure" else "somebody summon"
        object = if p == 1  -- works, because exact number sent, not dice
                 then MU.Text $ fromGroupName grp
                 else MU.Ws $ MU.Text $ fromGroupName grp
    return $! makeSentence ["you hear", verb, object]
  HearTaunt t ->
    return $! makeSentence ["you overhear", MU.Text t]

-- * RespSfxAtomicUI

-- | Display special effects (text, animation) sent to the client.
-- Don't modify client state (except a few fields), but only client
-- session (e.g., by displaying messages). This is enforced by types.
displayRespSfxAtomicUI :: MonadClientUI m => SfxAtomic -> m ()
{-# INLINE displayRespSfxAtomicUI #-}
displayRespSfxAtomicUI sfx = case sfx of
  SfxStrike source target iid ->
    strike False source target iid
  SfxRecoil source target _ -> do
    spart <- partActorLeader source
    tpart <- partActorLeader target
    msgAdd MsgAction $
      makeSentence [MU.SubjectVerbSg spart "shrink away from", tpart]
  SfxSteal source target iid ->
    strike True source target iid
  SfxRelease source target _ -> do
    spart <- partActorLeader source
    tpart <- partActorLeader target
    msgAdd MsgAction $ makeSentence [MU.SubjectVerbSg spart "release", tpart]
  SfxProject aid iid ->
    itemAidVerbMU MsgAction aid "fling" iid (Left $ Just 1)
  SfxReceive aid iid ->
    itemAidVerbMU MsgAction aid "receive" iid (Left $ Just 1)
  SfxApply aid iid -> do
    CCUI{coscreen=ScreenContent{rapplyVerbMap}} <- getsSession sccui
    ItemFull{itemKind} <- getsState $ itemToFull iid
    let actionPart = case EM.lookup (IK.isymbol itemKind) rapplyVerbMap of
          Just verb -> MU.Text verb
          Nothing -> "use"
    itemAidVerbMU MsgAction aid actionPart iid (Left $ Just 1)
  SfxCheck aid iid ->
    itemAidVerbMU MsgAction aid "deapply" iid (Left $ Just 1)
  SfxTrigger aid p -> do
    COps{cotile} <- getsState scops
    b <- getsState $ getActorBody aid
    lvl <- getLevel $ blid b
    let name = TK.tname $ okind cotile $ lvl `at` p
        (msgClass, verb) = if p == bpos b
                           then (MsgActionMinor, "walk over")
                           else (MsgAction, "exploit")
          -- TODO: "struggle" when harmful, "wade through" when deep, etc.
          -- possibly use the verb from the first embedded item,
          -- but it's meant to go with the item as subject, no the actor
          -- TODO: "harass" when somebody else suffers the effect
    aidVerbMU msgClass aid $ MU.Text $ verb <+> name
  SfxShun aid _p ->
    aidVerbMU MsgAction aid "shun it"
  SfxEffect fidSource aid effect hpDelta -> do
    b <- getsState $ getActorBody aid
    bUI <- getsSession $ getActorUI aid
    side <- getsClient sside
    mleader <- getsClient sleader
    let fid = bfid b
        isOurCharacter = fid == side && not (bproj b)
        isOurAlive = isOurCharacter && bhp b > 0
        isOurLeader = Just aid == mleader
        feelLookHP = feelLook MsgEffect
        feelLookCalm adjective =
          when (bhp b > 0) $ feelLook MsgEffectMinor adjective
        feelLook msgClass adjective =
          let verb = if isOurCharacter then "feel" else "look"
          in aidVerbMU msgClass aid $ MU.Text $ verb <+> adjective
    case effect of
        IK.Burn{} -> do
          feelLookHP "burned"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash ps Color.BrRed Color.Brown
        IK.Explode{} -> return ()  -- lots of visual feedback
        IK.RefillHP p | p == 1 -> return ()  -- no spam from regeneration
        IK.RefillHP p | p == -1 -> return ()  -- no spam from poison
        IK.RefillHP{} | hpDelta > 0 -> do
          feelLookHP "healthier"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash ps Color.BrGreen Color.Green
        IK.RefillHP{} -> do
          feelLookHP "wounded"
          let ps = (bpos b, bpos b)
          animate (blid b) $ twirlSplash ps Color.BrRed Color.Red
        IK.RefillCalm{} | bproj b -> return ()
        IK.RefillCalm p | p == 1 -> return ()  -- no spam from regen items
        IK.RefillCalm p | p > 0 -> feelLookCalm "calmer"
        IK.RefillCalm _ -> feelLookCalm "agitated"
        IK.Dominate -> do
          -- For subsequent messages use the proper name, never "you".
          let subject = partActor bUI
          if fid /= fidSource then do
            -- Before domination, possibly not seen if actor (yet) not ours.
            if | bcalm b == 0 ->  -- sometimes only a coincidence, but nm
                 aidVerbMU MsgEffectMinor aid
                 $ MU.Text "yield, under extreme pressure"
               | isOurAlive ->
                 aidVerbMU MsgEffectMinor aid
                 $ MU.Text "black out, dominated by foes"
               | otherwise ->
                 aidVerbMU MsgEffectMinor aid
                 $ MU.Text "decide abruptly to switch allegiance"
            fidName <- getsState $ gname . (EM.! fid) . sfactionD
            let verb = "be no longer controlled by"
            msgAdd MsgEffectMajor $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidName]
            when isOurAlive $ displayMoreKeep ColorFull ""
          else do
            -- After domination, possibly not seen, if actor (already) not ours.
            fidSourceName <- getsState $ gname . (EM.! fidSource) . sfactionD
            let verb = "be now under"
            msgAdd MsgEffectMajor $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidSourceName, "control"]
        IK.Impress -> aidVerbMU MsgEffectMinor aid "be awestruck"
        IK.PutToSleep -> aidVerbMU MsgEffectMajor aid "be put to sleep"
        IK.Yell -> aidVerbMU MsgMisc aid "start"
        IK.Summon grp p -> do
          let verb = if bproj b then "lure" else "summon"
              object = (if p == 1  -- works, because exact number sent, not dice
                        then MU.AW
                        else MU.Ws) $ MU.Text $ fromGroupName grp
          aidVerbMU MsgEffectMajor aid $ MU.Phrase [verb, object]
        IK.Ascend up -> do
          COps{cocave} <- getsState scops
          aidVerbMU MsgEffectMajor aid $ MU.Text $
            "find a way" <+> if up then "upstairs" else "downstairs"
          when isOurLeader $ do
            destinations <- getsState $ whereTo (blid b) (bpos b) up
                                        . sdungeon
            case destinations of
              (lid, _) : _ -> do  -- only works until different levels possible
                lvl <- getLevel lid
                let desc = cdesc $ okind cocave $ lkind lvl
                unless (T.null desc) $
                  msgAdd0 MsgLandscape $ desc <> "\n"
              [] -> return ()  -- spell fizzles; normally should not be sent
        IK.Escape{} | isOurCharacter -> do
          ours <- getsState $ fidActorNotProjGlobalAssocs side
          when (length ours > 1) $ do
            let object = partActor bUI
            msgAdd MsgOutcome $
              "The team joins" <+> makePhrase [object]
              <> ", forms a perimeter, repacks its belongings and leaves triumphant."
        IK.Escape{} -> return ()
        IK.Paralyze{} -> aidVerbMU MsgEffect aid "be paralyzed"
        IK.ParalyzeInWater{} ->
          aidVerbMU MsgEffectMinor aid "move with difficulty"
        IK.InsertMove d ->
          if Dice.supDice d >= 10
          then aidVerbMU MsgEffect aid "act with extreme speed"
          else aidVerbMU MsgEffectMinor aid "move swiftly"
        IK.Teleport t | Dice.supDice t <= 9 ->
          aidVerbMU MsgEffectMinor aid "blink"
        IK.Teleport{} -> aidVerbMU MsgEffect aid "teleport"
        IK.CreateItem{} -> return ()
        IK.DropItem _ _ COrgan _ -> return ()
        IK.DropItem{} -> aidVerbMU MsgEffect aid "be stripped"
        IK.PolyItem -> do
          subject <- partActorLeader aid
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd MsgEffect $ makeSentence
            [ MU.SubjectVerbSg subject "repurpose", "what lies", ppstore
            , "to a common item of the current level" ]
        IK.RerollItem -> do
          subject <- partActorLeader aid
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd MsgEffect $ makeSentence
            [ MU.SubjectVerbSg subject "reshape", "what lies", ppstore
            , "striving for the highest possible standards" ]
        IK.DupItem -> do
          subject <- partActorLeader aid
          let ppstore = MU.Text $ ppCStoreIn CGround
          msgAdd MsgEffect $ makeSentence
            [MU.SubjectVerbSg subject "multiply", "what lies", ppstore]
        IK.Identify -> do
          subject <- partActorLeader aid
          pronoun <- partPronounLeader aid
          msgAdd MsgEffectMinor $ makeSentence
            [ MU.SubjectVerbSg subject "look at"
            , MU.WownW pronoun $ MU.Text "inventory"
            , "intensely" ]
        IK.Detect d _ -> do
          subject <- partActorLeader aid
          let verb = MU.Text $ detectToVerb d
              object = MU.Ws $ MU.Text $ detectToObject d
          msgAdd MsgEffectMinor $
            makeSentence [MU.SubjectVerbSg subject verb, object]
          -- Don't make it modal if all info remains after no longer seen.
          unless (d `elem` [IK.DetectHidden, IK.DetectExit]) $
            displayMore ColorFull ""
        IK.SendFlying{} -> aidVerbMU MsgEffect aid "be sent flying"
        IK.PushActor{} -> aidVerbMU MsgEffect aid "be pushed"
        IK.PullActor{} -> aidVerbMU MsgEffect aid "be pulled"
        IK.DropBestWeapon -> aidVerbMU MsgEffectMajor aid "be disarmed"
        IK.ApplyPerfume ->
          msgAdd MsgEffectMinor
                 "The fragrance quells all scents in the vicinity."
        IK.OneOf{} -> return ()
        IK.OnSmash{} -> error $ "" `showFailure` sfx
        IK.VerbNoLonger t -> aidVerbMU MsgNoLonger aid $ MU.Text t
        IK.VerbMsg t -> aidVerbMU MsgEffectMinor aid $ MU.Text t
        IK.Composite{} -> error $ "" `showFailure` sfx
  SfxMsgFid _ sfxMsg -> do
    mleader <- getsClient sleader
    case mleader of
      Just{} -> return ()  -- will display stuff when leader moves
      Nothing -> do
        lidV <- viewedLevelUI
        markDisplayNeeded lidV
        recordHistory
    mmsg <- ppSfxMsg sfxMsg
    case mmsg of
      Just (msgClass, msg) -> msgAdd msgClass msg
      Nothing -> return ()
  SfxRestart -> fadeOutOrIn True
  SfxCollideTile source pos -> do
    COps{cotile} <- getsState scops
    sb <- getsState $ getActorBody source
    lvl <- getLevel $ blid sb
    spart <- partActorLeader source
    let object = MU.AW $ MU.Text $ TK.tname $ okind cotile $ lvl `at` pos
    msgAdd MsgVeryRare $! makeSentence
      [MU.SubjectVerbSg spart "collide", "painfully with", object]
  SfxTaunt voluntary aid -> do
    spart <- partActorLeader aid
    (_heardSubject, verb) <- displayTaunt voluntary rndToActionForget aid
    msgAdd MsgMisc $! makeSentence [MU.SubjectVerbSg spart (MU.Text verb)]

ppSfxMsg :: MonadClientUI m => SfxMsg -> m (Maybe (MsgClass, Text))
ppSfxMsg sfxMsg = case sfxMsg of
  SfxUnexpected reqFailure -> return $
    Just ( MsgWarning
         , "Unexpected problem:" <+> showReqFailure reqFailure <> "." )
  SfxExpected itemName reqFailure -> return $
    Just ( MsgWarning
         , "The" <+> itemName <+> "is not triggered:"
           <+> showReqFailure reqFailure <> "." )
  SfxFizzles -> return $ Just (MsgWarning, "It didn't work.")
  SfxNothingHappens -> return $ Just (MsgMisc, "Nothing happens.")
  SfxVoidDetection d -> return $
    Just ( MsgMisc
         , makeSentence ["no new", MU.Text $ detectToObject d, "detected"] )
  SfxUnimpressed aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "be unimpressed"
        return $ Just (MsgWarning, makeSentence [MU.SubjectVerbSg subject verb])
  SfxSummonLackCalm aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "lack Calm to summon"
        return $ Just (MsgWarning, makeSentence [MU.SubjectVerbSg subject verb])
  SfxSummonTooManyOwn aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "can't keep track of their numerous friends, let alone summon any more"
        return $ Just (MsgWarning, makeSentence [subject, verb])
  SfxSummonTooManyAll aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "can't keep track of everybody around, let alone summon anyone else"
        return $ Just (MsgWarning, makeSentence [subject, verb])
  SfxSummonFailure aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "fail to summon anything"
        return $ Just (MsgWarning, makeSentence [MU.SubjectVerbSg subject verb])
  SfxLevelNoMore ->
    return $ Just (MsgWarning, "No more levels in this direction.")
  SfxLevelPushed ->
    return $ Just (MsgWarning, "You notice somebody pushed to another level.")
  SfxBracedImmune aid -> do
    msbUI <- getsSession $ EM.lookup aid . sactorUI
    case msbUI of
      Nothing -> return Nothing
      Just sbUI -> do
        let subject = partActor sbUI
            verb = "be braced and so immune to translocation"
        return $ Just (MsgMisc, makeSentence [MU.SubjectVerbSg subject verb])
                         -- too common
  SfxEscapeImpossible -> return $
    Just ( MsgWarning
         , "Escaping outside is unthinkable for members of this faction." )
  SfxStasisProtects -> return $
    Just ( MsgMisc  -- too common
         , "Paralysis and speed surge require recovery time." )
  SfxWaterParalysisResisted -> return Nothing  -- don't spam
  SfxTransImpossible -> return $
    Just (MsgWarning, "Translocation not possible.")
  SfxIdentifyNothing -> return $ Just (MsgWarning, "Nothing to identify.")
  SfxPurposeNothing -> return $
    Just ( MsgWarning
         , "The purpose of repurpose cannot be availed without an item"
           <+> ppCStoreIn CGround <> "." )
  SfxPurposeTooFew maxCount itemK -> return $
    Just ( MsgWarning
         , "The purpose of repurpose is served by" <+> tshow maxCount
           <+> "pieces of this item, not by" <+> tshow itemK <> "." )
  SfxPurposeUnique -> return $
    Just (MsgWarning, "Unique items can't be repurposed.")
  SfxPurposeNotCommon -> return $
    Just (MsgWarning, "Only ordinary common items can be repurposed.")
  SfxRerollNothing -> return $
    Just ( MsgWarning
         , "The shape of reshape cannot be assumed without an item"
           <+> ppCStoreIn CGround <> "." )
  SfxRerollNotRandom -> return $
    Just (MsgWarning, "Only items of variable shape can be reshaped.")
  SfxDupNothing -> return $
    Just ( MsgWarning
         , "Mutliplicity won't rise above zero without an item"
           <+> ppCStoreIn CGround <> "." )
  SfxDupUnique -> return $
    Just (MsgWarning, "Unique items can't be multiplied.")
  SfxDupValuable -> return $
    Just (MsgWarning, "Valuable items can't be multiplied.")
  SfxColdFish -> return $
    Just ( MsgMisc  -- repeatable
         , "Healing attempt from another faction is thwarted by your cold fish attitude." )
  SfxTimerExtended lid aid iid cstore delta -> do
    aidSeen <- getsState $ memActor aid lid
    if aidSeen then do
      b <- getsState $ getActorBody aid
      bUI <- getsSession $ getActorUI aid
        -- assume almost always a prior message mentions the object
      factionD <- getsState sfactionD
      localTime <- getsState $ getLocalTime (blid b)
      itemFull <- getsState $ itemToFull iid
      side <- getsClient sside
      let kit = (1, [])
          (name, powers) = partItem (bfid b) factionD localTime itemFull kit
      storeOwn <- ppContainerWownW partPronounLeader True (CActor aid cstore)
      let cond = [ "condition"
                 | IA.checkFlag Ability.Condition $ aspectRecordFull itemFull ]
          -- Note that when enemy actor causes the extension to himsefl,
          -- the player is not notified at all. So the shorter blurb below
          -- is the middle ground.
          (msgClass, parts) | bfid b == side =
            ( MsgLongerUs
            , ["the", name, powers] ++ cond ++ storeOwn ++ ["will now last"]
              ++ [MU.Text $ timeDeltaInSecondsText delta] ++ ["longer"] )
                | otherwise =  -- avoid TMI for not our actors
            -- Ideally we'd use a pronoun here, but the action (e.g., hit)
            -- that caused this extension can be invisible to some onlookers.
            -- So their narrative context needs to be taken into account.
            ( MsgLonger
            , [partItemShortWownW side factionD (partActor bUI) localTime
                                       itemFull (1, [])]
              ++ cond ++ ["is extended"] )
      return $ Just (msgClass, makeSentence parts)
    else return Nothing
  SfxCollideActor lid source target -> do
    sourceSeen <- getsState $ memActor source lid
    targetSeen <- getsState $ memActor target lid
    if sourceSeen && targetSeen then do
      spart <- partActorLeader source
      tpart <- partActorLeader target
      return $
        Just ( MsgWarning
             , makeSentence
                 [MU.SubjectVerbSg spart "collide", "awkwardly with", tpart] )
    else return Nothing

strike :: MonadClientUI m => Bool -> ActorId -> ActorId -> ItemId -> m ()
strike catch source target iid = assert (source /= target) $ do
  tb <- getsState $ getActorBody target
  sourceSeen <- getsState $ memActor source (blid tb)
  if not sourceSeen then
    animate (blid tb) $ subtleHit (bpos tb)
  else do
    hurtMult <- getsState $ armorHurtBonus source target
    sb <- getsState $ getActorBody source
    sMaxSk <- getsState $ getActorMaxSkills source
    spart <- partActorLeader source
    tpart <- partActorLeader target
    spronoun <- partPronounLeader source
    tpronoun <- partPronounLeader target
    tbUI <- getsSession $ getActorUI target
    localTime <- getsState $ getLocalTime (blid tb)
    itemFullWeapon <- getsState $ itemToFull iid
    let kitWeapon = (1, [])
    side <- getsClient sside
    factionD <- getsState sfactionD
    tfact <- getsState $ (EM.! bfid tb) . sfactionD
    eqpOrgKit <- getsState $ kitAssocs target [CEqp, COrgan]
    orgKit <- getsState $ kitAssocs target [COrgan]
    let notCond (_, (itemFullArmor, _)) =
          not $ IA.checkFlag Ability.Condition $ aspectRecordFull itemFullArmor
        isOrdinaryCond (_, (itemFullArmor, _)) =
          isJust $ lookup "condition" $ IK.ifreq $ itemKind itemFullArmor
        rateArmor (iidArmor, (itemFullArmor, (k, _))) =
          ( k * IA.getSkill Ability.SkArmorMelee
                            (aspectRecordFull itemFullArmor)
          , ( iidArmor
            , itemFullArmor ) )
        abs15 (v, _) = abs v >= 15
        condArmor = filter abs15 $ map rateArmor $ filter isOrdinaryCond orgKit
        fstGt0 (v, _) = v > 0
        eqpAndOrgArmor = filter fstGt0 $ map rateArmor
                         $ filter notCond eqpOrgKit
    mblockArmor <- case eqpAndOrgArmor of
      [] -> return Nothing
      _ -> Just
           <$> rndToActionForget (frequency $ toFreq "msg armor" eqpAndOrgArmor)
    let (blockWithWhat, blockWithWeapon) = case mblockArmor of
          Nothing -> ([], False)
          Just (iidArmor, itemFullArmor) ->
            let (object1, object2) =
                  partItemShortest (bfid tb) factionD localTime
                                   itemFullArmor (1, [])
                name | iidArmor == btrunk tb = "trunk"
                     | otherwise = MU.Phrase [object1, object2]
            in ( ["with", MU.WownW tpronoun name]
               , Dice.supDice (IK.idamage $ itemKind itemFullArmor) > 0 )
        verb = MU.Text $ IK.iverbHit $ itemKind itemFullWeapon
        partItemChoice =
          if iid `EM.member` borgan sb
          then partItemShortWownW side factionD spronoun localTime
          else partItemShortAW side factionD localTime
        weaponName = partItemChoice itemFullWeapon kitWeapon
        sleepy = if bwatch tb `elem` [WSleep, WWake]
                    && tpart /= "you"
                    && bhp tb > 0
                 then "the sleepy"
                 else ""
        -- For variety, attack adverb is based on attacker's and weapon's
        -- damage potential as compared to victim's current HP.
        -- We are not taking into account victim's armor yet.
        sHurt = armorHurtCalculation (bproj sb) sMaxSk Ability.zeroSkills
        sDamage =
          let dmg = Dice.supDice $ IK.idamage $ itemKind itemFullWeapon
              rawDeltaHP = fromIntegral sHurt * xM dmg `divUp` 100
              speedDeltaHP = case btrajectory sb of
                Just (_, speed) | bproj sb ->
                  - modifyDamageBySpeed rawDeltaHP speed
                _ -> - rawDeltaHP
          in min 0 speedDeltaHP
        deadliness = 1000 * (- sDamage) `div` max 1 (bhp tb)
        strongly
          | deadliness >= 10000 = "artfully"
          | deadliness >= 5000 = "madly"
          | deadliness >= 2000 = "mercilessly"
          | deadliness >= 1000 = "murderously"  -- one blow can wipe out all HP
          | deadliness >= 700 = "devastatingly"
          | deadliness >= 500 = "vehemently"
          | deadliness >= 400 = "forcefully"
          | deadliness >= 350 = "sturdily"
          | deadliness >= 300 = "accurately"
          | deadliness >= 20 = ""  -- common, terse case, between 2% and 30%
          | deadliness >= 10 = "cautiously"
          | deadliness >= 5 = "guardedly"
          | deadliness >= 3 = "hesitantly"
          | deadliness >= 2 = "clumsily"
          | deadliness >= 1 = "haltingly"
          | otherwise = "feebly"
        -- Here we take into account armor, so we look at @hurtMult@,
        -- so we finally convey the full info about effectiveness of the strike.
        blockHowWell  -- under some conditions, the message not shown at all
          | hurtMult > 90 = "incompetently"
          | hurtMult > 80 = "too late"
          | hurtMult > 70 = "too slowly"
          | hurtMult > 20 = if | deadliness >= 2000 -> "marginally"
                               | deadliness >= 1000 -> "partially"
                               | deadliness >= 100 -> "partly"  -- common
                               | deadliness >= 50 -> "to an extent"
                               | deadliness >= 20 -> "to a large extent"
                               | deadliness >= 5 -> "for the major part"
                               | otherwise -> "for the most part"
          | hurtMult > 1 = if | actorWaits tb -> "doggedly"
                              | hurtMult > 10 -> "nonchalantly"
                              | otherwise -> "bemusedly"
          | otherwise = "almost completely"
              -- 1% always gets through, but if fast missile, can be deadly
        blockPhrase =
          let (subjectBlock, verbBlock) =
                if | not $ bproj sb ->
                     (tpronoun, if blockWithWeapon
                                then "parry"
                                else "block")
                   | tpronoun == "it"
                     || projectileHitsWeakly && tpronoun /= "you" ->
                     -- Avoid ambiguity.
                     (partActor tbUI, if actorWaits tb
                                      then "deflect it"
                                      else "fend it off")
                   | otherwise ->
                     (tpronoun, if actorWaits tb
                                then "avert it"
                                else "ward it off")
          in MU.SubjectVerbSg subjectBlock verbBlock
        surprisinglyGoodDefense = deadliness >= 20 && hurtMult <= 70
        surprisinglyBadDefense = deadliness < 20 && hurtMult > 70
        yetButAnd
          | surprisinglyGoodDefense = ", but"
          | surprisinglyBadDefense = ", yet"
          | otherwise = " and"  -- no surprises
        projectileHitsWeakly = bproj sb && deadliness < 20
        msgArmor = if not projectileHitsWeakly
                        -- ensures if attack msg terse, armor message
                        -- mentions object, so we know who is hit
                      && hurtMult > 90
                      && (null condArmor || deadliness < 100)
                   then ""  -- at most minor armor, relatively to skill
                            -- of the hit, so we don't talk about blocking,
                            -- unless a condition is at play, too
                   else yetButAnd
                        <+> makePhrase ([blockPhrase, blockHowWell]
                                        ++ blockWithWhat)
        ps = (bpos tb, bpos sb)
        basicAnim
          | hurtMult > 70 = twirlSplash ps Color.BrRed Color.Red
          | hurtMult > 1 = blockHit ps Color.BrRed Color.Red
          | otherwise = blockMiss ps
        targetIsFoe = bfid sb == side  -- no big news if others hit our foes
                      && isFoe (bfid tb) tfact side
        targetIsFriend = isFriend (bfid tb) tfact side
                           -- warning if anybody hits our friends
        msgClassMelee = if targetIsFriend then MsgMeleeUs else MsgMelee
        msgClassRanged = if targetIsFriend then MsgRangedUs else MsgRanged
    -- The messages about parrying and immediately afterwards dying
    -- sound goofy, but there is no easy way to prevent that.
    -- And it's consistent.
    -- If/when death blow instead sets HP to 1 and only the next below 1,
    -- we can check here for HP==1; also perhaps actors with HP 1 should
    -- not be able to block.
    if | catch -> do  -- charge not needed when catching
         let msg = makeSentence
                     [MU.SubjectVerbSg spart "catch", tpart, "skillfully"]
         msgAdd MsgVeryRare msg
         animate (blid tb) $ blockHit ps Color.BrGreen Color.Green
       | not (hasCharge localTime itemFullWeapon kitWeapon) -> do
         -- Can easily happen with a thrown discharged item.
         -- Much less plausible with a wielded weapon.
         -- Theoretically possible if the weapon not identified
         -- (then timeout is a mean estimate), but they usually should be,
         -- even in foes' possession.
         let msg = if bproj sb
                   then makePhrase
                          [MU.Capitalize $ MU.SubjectVerbSg spart "connect"]
                        <> ", but it may be completely discharged."
                   else makePhrase
                          [ MU.Capitalize $ MU.SubjectVerbSg spart "try"
                          , "to", verb, tpart, "with"
                          , weaponName ]
                        <> ", but it may be not readied yet."
         msgAdd MsgVeryRare msg  -- and no animation
       | bproj sb && bproj tb -> do  -- server sends unless both are blasts
         -- Short message.
         msgAdd MsgVeryRare $
           makeSentence [MU.SubjectVerbSg spart "intercept", tpart]
         -- Basic non-bloody animation regardless of stats.
         animate (blid tb) $ blockHit ps Color.BrBlue Color.Blue
       | IK.idamage (itemKind itemFullWeapon) == 0 -> do
         let adverb = if bproj sb then "lightly" else "delicately"
             msg = makeSentence $
               [MU.SubjectVerbSg spart verb, tpart, adverb]
               ++ if bproj sb then [] else ["with", weaponName]
         msgAdd msgClassMelee msg  -- too common for color
         animate (blid tb) $ subtleHit (bpos sb)
       | bproj sb -> do  -- more terse than melee, because sometimes very spammy
         let msgRangedPowerful | targetIsFoe = MsgRangedPowerfulWe
                               | targetIsFriend = MsgRangedPowerfulUs
                               | otherwise = msgClassRanged
             (attackParts, msgRanged)
               | projectileHitsWeakly =
                 ( [MU.SubjectVerbSg spart "connect"]  -- weak, so terse
                 , msgClassRanged )
               | deadliness >= 300 =
                 ( [MU.SubjectVerbSg spart verb, tpart, "powerfully"]
                 , if targetIsFriend || deadliness >= 700
                   then msgRangedPowerful
                   else msgClassRanged )
               | otherwise =
                 ( [MU.SubjectVerbSg spart verb, tpart]  -- strong, for a proj
                 , msgClassRanged )
         msgAdd msgRanged $ makePhrase [MU.Capitalize $ MU.Phrase attackParts]
                            <> msgArmor <> "."
         animate (blid tb) basicAnim
       | bproj tb -> do  -- much less emotion and the victim not active.
         let attackParts =
               [MU.SubjectVerbSg spart verb, tpart, "with", weaponName]
         msgAdd MsgMelee $ makeSentence attackParts
         animate (blid tb) basicAnim
       | otherwise -> do  -- ordinary melee
         let msgMeleeInteresting | targetIsFoe = MsgMeleeInterestingWe
                                 | targetIsFriend = MsgMeleeInterestingUs
                                 | otherwise = msgClassMelee
             msgMeleePowerful | targetIsFoe = MsgMeleePowerfulWe
                              | targetIsFriend = MsgMeleePowerfulUs
                              | otherwise = msgClassMelee
             attackParts =
               [ MU.SubjectVerbSg spart verb, sleepy, tpart, strongly
               , "with", weaponName ]
             (tmpInfluenceBlurb, msgClassInfluence) =
               if null condArmor || T.null msgArmor
               then ("", msgClassMelee)
               else
                 let (armor, (_, itemFullArmor)) =
                       maximumBy (Ord.comparing $ abs . fst) condArmor
                     (object1, object2) =
                       partItemShortest (bfid tb) factionD localTime
                                        itemFullArmor (1, [])
                     name = makePhrase [object1, object2]
                     msgText =
                       if hurtMult > 20 && not surprisinglyGoodDefense
                          || surprisinglyBadDefense
                       then (if armor <= -15
                             then ", due to being"
                             else assert (armor >= 15) ", regardless of being")
                            <+> name
                       else (if armor >= 15
                             then ", thanks to being"
                             else assert (armor <= -15) ", despite being")
                            <+> name
                 in (msgText, msgMeleeInteresting)
             msgClass = if targetIsFriend && deadliness >= 300
                           || deadliness >= 2000
                        then msgMeleePowerful
                        else msgClassInfluence
         msgAdd msgClass $ makePhrase [MU.Capitalize $ MU.Phrase attackParts]
                           <> msgArmor <> tmpInfluenceBlurb <> "."
         animate (blid tb) basicAnim
