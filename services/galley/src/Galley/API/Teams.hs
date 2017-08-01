{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Galley.API.Teams
    ( createBindingTeam
    , createNonBindingTeam
    , updateTeam
    , getTeam
    , getManyTeams
    , deleteTeam
    , uncheckedDeleteTeam
    , addTeamMember
    , getTeamMembers
    , getTeamMember
    , deleteTeamMember
    , getTeamConversations
    , getTeamConversation
    , deleteTeamConversation
    , updateTeamMember
    , uncheckedAddTeamMember
    , uncheckedGetTeamMember
    , uncheckedRemoveTeamMember
    ) where

import Cassandra (result, hasMore)
import Control.Concurrent.Async (mapConcurrently)
import Control.Lens
import Control.Monad (unless, when, void)
import Control.Monad.Catch
import Control.Monad.IO.Class
import Data.ByteString.Conversion hiding (fromList)
import Data.Foldable (for_, foldrM)
import Data.Int
import Data.Id
import Data.List1 (list1)
import Data.Maybe (catMaybes, isJust)
import Data.Range
import Data.Time.Clock (getCurrentTime)
import Data.Traversable (mapM)
import Data.Set (fromList, toList)
import Galley.App
import Galley.API.Error
import Galley.API.Util
import Galley.Intra.Push
import Galley.Intra.User
import Galley.Types.Teams
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Predicate hiding (setStatus, result, or)
import Network.Wai.Utilities
import Prelude hiding (head, mapM)

import qualified Data.Set as Set
import qualified Galley.Data as Data
import qualified Galley.Data.Types as Data
import qualified Galley.Queue as Q
import qualified Galley.Types as Conv
import qualified Galley.Types.Teams as Teams

getTeam :: UserId ::: TeamId ::: JSON -> Galley Response
getTeam (zusr::: tid ::: _) =
    maybe (throwM teamNotFound) (pure . json) =<< lookupTeam zusr tid

getManyTeams :: UserId ::: Maybe (Either (Range 1 32 (List TeamId)) TeamId) ::: Range 1 100 Int32 ::: JSON -> Galley Response
getManyTeams (zusr ::: range ::: size ::: _) =
    withTeamIds zusr range size $ \more ids -> do
        teams <- mapM (lookupTeam zusr) ids
        pure (json $ newTeamList (catMaybes teams) more)

lookupTeam :: UserId -> TeamId -> Galley (Maybe Team)
lookupTeam zusr tid = do
    tm <- Data.teamMember tid zusr
    if isJust tm then do
        t <- Data.team tid
        when (Just True == (Data.tdDeleted <$> t)) $ do
            q <- view deleteQueue
            void $ Q.tryPush q (TeamItem tid zusr Nothing)
        pure (Data.tdTeam <$> t)
    else
        pure Nothing

createNonBindingTeam :: UserId ::: ConnId ::: Request ::: JSON ::: JSON -> Galley Response
createNonBindingTeam (zusr::: zcon ::: req ::: _) = do
    NonBindingNewTeam body <- fromBody req invalidPayload
    let owner  = newTeamMember zusr fullPermissions
    let others = filter ((zusr /=) . view userId)
               . maybe [] fromRange
               $ body^.newTeamMembers
    let zothers = map (view userId) others
    ensureUnboundUsers (zusr : zothers)
    ensureConnected zusr zothers
    team <- Data.createTeam Nothing zusr (body^.newTeamName) (body^.newTeamIcon) (body^.newTeamIconKey) NonBinding
    finishCreateTeam team owner others (Just zcon)

createBindingTeam :: UserId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
createBindingTeam (zusr ::: tid ::: req ::: _) = do
    BindingNewTeam body <- fromBody req invalidPayload
    let owner  = newTeamMember zusr fullPermissions
    team <- Data.createTeam (Just tid) zusr (body^.newTeamName) (body^.newTeamIcon) (body^.newTeamIconKey) Binding
    finishCreateTeam team owner [] Nothing

updateTeam :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
updateTeam (zusr::: zcon ::: tid ::: req ::: _) = do
    body <- fromBody req invalidPayload
    membs <- Data.teamMembers tid
    void $ permissionCheck zusr SetTeamData membs
    Data.updateTeam tid body
    now <- liftIO getCurrentTime
    let e = newEvent TeamUpdate tid now & eventData .~ Just (EdTeamUpdate body)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) membs)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    pure empty

deleteTeam :: UserId ::: ConnId ::: TeamId ::: Request ::: Maybe JSON ::: JSON -> Galley Response
deleteTeam (zusr::: zcon ::: tid ::: req ::: _ ::: _) = do
    team <- Data.team tid >>= ifNothing teamNotFound
    unless (Data.tdDeleted team) $ do
        void $ permissionCheck zusr DeleteTeam =<< Data.teamMembers tid
        when ((Data.tdTeam team)^.teamBinding == Binding) $ do
            body <- fromBody req invalidPayload
            ensureReAuthorised zusr (body^.tdAuthPassword)
    q  <- view deleteQueue
    ok <- Q.tryPush q (TeamItem tid zusr (Just zcon))
    if ok then
        pure (empty & setStatus status202)
    else
        throwM deleteQueueFull

-- This function is "unchecked" because it does not validate that the user has the `DeleteTeam` permission.
uncheckedDeleteTeam :: UserId -> Maybe ConnId -> TeamId -> Galley ()
uncheckedDeleteTeam zusr zcon tid = do
    team <- Data.team tid
    when (isJust team) $ do
        membs  <- Data.teamMembers tid
        now    <- liftIO getCurrentTime
        convs  <- filter (not . view managedConversation) <$> Data.teamConversations tid
        events <- foldrM (pushEvents now membs) [] convs
        let e = newEvent TeamDelete tid now
        let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) membs)
        pushSome ((newPush1 zusr (TeamEvent e) r & pushConn .~ zcon) : events)
        when ((view teamBinding . Data.tdTeam <$> team) == Just Binding) $
            mapM_ (deleteUser . view userId) membs
        Data.deleteTeam tid
  where
    pushEvents now membs c pp = do
        mm <- flip nonTeamMembers membs <$> Data.members (c^.conversationId)
        let e = Conv.Event Conv.ConvDelete (c^.conversationId) zusr now Nothing
        let p = newPush zusr (ConvEvent e) (map recipient mm)
        pure (maybe pp (\x -> (x & pushConn .~ zcon) : pp) p)

getTeamMembers :: UserId ::: TeamId ::: JSON -> Galley Response
getTeamMembers (zusr::: tid ::: _) = do
    mems <- Data.teamMembers tid
    case findTeamMember zusr mems of
        Nothing -> throwM noTeamMember
        Just  m -> do
            let withPerm = m `hasPermission` GetMemberPermissions
            pure (json $ teamMemberListJson withPerm (newTeamMemberList mems))

getTeamMember :: UserId ::: TeamId ::: UserId ::: JSON -> Galley Response
getTeamMember (zusr::: tid ::: uid ::: _) = do
    mems <- Data.teamMembers tid
    case findTeamMember zusr mems of
        Nothing -> throwM noTeamMember
        Just  m -> do
            let withPerm = m `hasPermission` GetMemberPermissions
            let member   = findTeamMember uid mems
            maybe (throwM teamMemberNotFound) (pure . json . teamMemberJson withPerm) member

uncheckedGetTeamMember :: TeamId ::: UserId ::: JSON -> Galley Response
uncheckedGetTeamMember (tid ::: uid ::: _) = do
    mem <- Data.teamMember tid uid >>= ifNothing teamMemberNotFound
    return . json $ teamMemberJson True mem

addTeamMember :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
addTeamMember (zusr::: zcon ::: tid ::: req ::: _) = do
    nmem <- fromBody req invalidPayload
    mems <- Data.teamMembers tid
    tmem <- permissionCheck zusr AddTeamMember mems
    unless ((nmem^.ntmNewTeamMember.permissions.self) `Set.isSubsetOf` (tmem^.permissions.copy)) $
        throwM invalidPermissions
    ensureNonBindingTeam tid
    ensureUnboundUsers [nmem^.ntmNewTeamMember.userId]
    ensureConnected zusr [nmem^.ntmNewTeamMember.userId]
    addTeamMemberInternal tid (Just zusr) (Just zcon) nmem mems

-- This function is "unchecked" because there is no need to check for user binding (invite only).
uncheckedAddTeamMember :: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
uncheckedAddTeamMember (tid ::: req ::: _) = do
    nmem <- fromBody req invalidPayload
    mems <- Data.teamMembers tid
    addTeamMemberInternal tid Nothing Nothing nmem mems

updateTeamMember :: UserId ::: ConnId ::: TeamId ::: Request ::: JSON ::: JSON -> Galley Response
updateTeamMember (zusr::: zcon ::: tid ::: req ::: _) = do
    body <- fromBody req invalidPayload
    let user = body^.ntmNewTeamMember.userId
    let perm = body^.ntmNewTeamMember.permissions
    members <- Data.teamMembers tid
    member  <- permissionCheck zusr SetMemberPermissions members
    unless ((perm^.self) `Set.isSubsetOf` (member^.permissions.copy)) $
        throwM invalidPermissions
    unless (isTeamMember user members) $
        throwM teamMemberNotFound
    Data.updateTeamMember tid user perm
    now <- liftIO getCurrentTime
    let e = newEvent MemberUpdate tid now & eventData .~ Just (EdMemberUpdate user)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) members)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ Just zcon
    pure empty

deleteTeamMember :: UserId ::: ConnId ::: TeamId ::: UserId ::: Request ::: Maybe JSON ::: JSON -> Galley Response
deleteTeamMember (zusr::: zcon ::: tid ::: remove ::: req ::: _ ::: _) = do
    mems <- Data.teamMembers tid
    void $ permissionCheck zusr RemoveTeamMember mems
    team <- Data.tdTeam <$> (Data.team tid >>= ifNothing teamNotFound)
    if (team^.teamBinding == Binding && isTeamMember remove mems) then do
        body <- fromBody req invalidPayload
        ensureReAuthorised zusr (body^.tmdAuthPassword)
        deleteUser remove
        pure (empty & setStatus status202)
    else do
        uncheckedRemoveTeamMember zusr (Just zcon) tid remove mems
        pure empty

-- This function is "unchecked" because it does not validate that the user has the `RemoveTeamMember` permission.
uncheckedRemoveTeamMember :: UserId -> Maybe ConnId -> TeamId -> UserId -> [TeamMember] -> Galley ()
uncheckedRemoveTeamMember zusr zcon tid remove mems = do
    now <- liftIO getCurrentTime
    let e = newEvent MemberLeave tid now & eventData .~ Just (EdMemberLeave remove)
    let r = list1 (userRecipient zusr) (membersToRecipients (Just zusr) mems)
    push1 $ newPush1 zusr (TeamEvent e) r & pushConn .~ zcon
    Data.removeTeamMember tid remove
    let tmids = Set.fromList $ map (view userId) mems
    let edata = Conv.EdMembers (Conv.Members [remove])
    cc <- Data.teamConversations tid
    for_ cc $ \c -> do
        Data.removeMember remove (c^.conversationId)
        unless (c^.managedConversation) $ do
            conv <- Data.conversation (c^.conversationId)
            for_ conv $ \dc -> do
                let x = filter (\m -> not (Conv.memId m `Set.member` tmids)) (Data.convMembers dc)
                let y = Conv.Event Conv.MemberLeave (Data.convId dc) zusr now (Just edata)
                for_ (newPush zusr (ConvEvent y) (recipient <$> x)) $ \p ->
                    push1 $ p & pushConn .~ zcon

getTeamConversations :: UserId ::: TeamId ::: JSON -> Galley Response
getTeamConversations (zusr::: tid ::: _) = do
    tm <- Data.teamMember tid zusr >>= ifNothing noTeamMember
    unless (tm `hasPermission` GetTeamConversations) $
        throwM (operationDenied GetTeamConversations)
    json . newTeamConversationList <$> Data.teamConversations tid

getTeamConversation :: UserId ::: TeamId ::: ConvId ::: JSON -> Galley Response
getTeamConversation (zusr::: tid ::: cid ::: _) = do
    tm <- Data.teamMember tid zusr >>= ifNothing noTeamMember
    unless (tm `hasPermission` GetTeamConversations) $
        throwM (operationDenied GetTeamConversations)
    Data.teamConversation tid cid >>= maybe (throwM convNotFound) (pure . json)

deleteTeamConversation :: UserId ::: ConnId ::: TeamId ::: ConvId ::: JSON -> Galley Response
deleteTeamConversation (zusr::: zcon ::: tid ::: cid ::: _) = do
    tmems <- Data.teamMembers tid
    void $ permissionCheck zusr DeleteConversation tmems
    cmems <- Data.members cid
    now <- liftIO getCurrentTime
    let te = newEvent Teams.ConvDelete tid now & eventData .~ Just (Teams.EdConvDelete cid)
    let ce = Conv.Event Conv.ConvDelete cid zusr now Nothing
    let tr = list1 (userRecipient zusr) (membersToRecipients (Just zusr) tmems)
    let p  = newPush1 zusr (TeamEvent te) tr & pushConn .~ Just zcon
    case map recipient (nonTeamMembers cmems tmems) of
        []     -> push1 p
        (m:mm) -> pushSome [p, newPush1 zusr (ConvEvent ce) (list1 m mm) & pushConn .~ Just zcon]
    Data.removeTeamConv tid cid
    pure empty

-- Internal -----------------------------------------------------------------

-- | Invoke the given continuation 'k' with a list of team IDs
-- which are looked up based on:
--
-- * just limited by size
-- * an (exclusive) starting point (team ID) and size
-- * a list of team IDs
--
-- The last case returns those team IDs which have an associated
-- user. Additionally 'k' is passed in a 'hasMore' indication (which is
-- always false if the third lookup-case is used).
withTeamIds :: UserId
            -> Maybe (Either (Range 1 32 (List TeamId)) TeamId)
            -> Range 1 100 Int32
            -> (Bool -> [TeamId] -> Galley Response)
            -> Galley Response
withTeamIds usr range size k = case range of
    Nothing        -> do
        Data.ResultSet r <- Data.teamIdsFrom usr Nothing (rcast size)
        k (hasMore r) (result r)

    Just (Right c) -> do
        Data.ResultSet r <- Data.teamIdsFrom usr (Just c) (rcast size)
        k (hasMore r) (result r)

    Just (Left cc) -> do
        ids <- Data.teamIdsOf usr cc
        k False ids
{-# INLINE withTeamIds #-}

ensureUnboundUsers :: [UserId] -> Galley ()
ensureUnboundUsers uids = do
    e  <- ask
    -- We check only 1 team because, by definition, users in binding teams
    -- can only be part of one team.
    ts <- liftIO $ mapConcurrently (evalGalley e . Data.oneUserTeam) uids
    let teams = toList $ fromList (catMaybes ts)
    binds <- liftIO $ mapConcurrently (evalGalley e . Data.teamBinding) teams
    when (any ((==) (Just Binding)) binds) $
        throwM userBindingExists

ensureNonBindingTeam :: TeamId -> Galley ()
ensureNonBindingTeam tid = do
    team <- Data.team tid >>= ifNothing teamNotFound
    when ((Data.tdTeam team)^.teamBinding == Binding) $
        throwM noAddToBinding

addTeamMemberInternal :: TeamId -> Maybe UserId -> Maybe ConnId -> NewTeamMember -> [TeamMember] -> Galley Response
addTeamMemberInternal tid origin originConn newMem mems = do
    let new = newMem^.ntmNewTeamMember
    unless (length mems < 128) $
        throwM tooManyTeamMembers
    Data.addTeamMember tid new
    cc <- filter (view managedConversation) <$> Data.teamConversations tid
    for_ cc $ \c ->
        Data.addMember (c^.conversationId) (new^.userId)
    now <- liftIO getCurrentTime
    let e = newEvent MemberJoin tid now & eventData .~ Just (EdMemberJoin (new^.userId))
    push1 $ newPush1 (new^.userId) (TeamEvent e) (r origin new) & pushConn .~ originConn
    pure empty
  where
    r (Just o) n = list1 (userRecipient o)           (membersToRecipients (Just o) (n : mems))
    r Nothing  n = list1 (userRecipient (n^.userId)) (membersToRecipients Nothing  (n : mems))

finishCreateTeam :: Team -> TeamMember -> [TeamMember] -> Maybe ConnId -> Galley Response
finishCreateTeam team owner others zcon = do
    let zusr = owner^.userId
    for_ (owner : others) $
        Data.addTeamMember (team^.teamId)
    now <- liftIO getCurrentTime
    let e = newEvent TeamCreate (team^.teamId) now & eventData .~ Just (EdTeamCreate team)
    let r = membersToRecipients Nothing others
    push1 $ newPush1 zusr (TeamEvent e) (list1 (userRecipient zusr) r) & pushConn .~ zcon
    pure (empty & setStatus status201 . location (team^.teamId))