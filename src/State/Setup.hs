{-# LANGUAGE TypeFamilies #-}
module State.Setup
  ( setupState
  )
where

import           Prelude ()
import           Prelude.MH

import           Brick.BChan
import           Brick.Themes (themeToAttrMap, loadCustomizations)
import qualified Control.Concurrent.STM as STM
import           Control.Concurrent.MVar (newMVar)
import           Control.Exception (catch)
import           Data.Maybe (fromJust)
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import           Lens.Micro.Platform ((%~))
import           System.Exit (exitFailure)
import           System.FilePath ((</>), isRelative, dropFileName)
import           System.IO (Handle)
import           System.IO.Error (catchIOError)

import           Network.Mattermost.Endpoints
import           Network.Mattermost.Types
import           Network.Mattermost.Logging (mmLoggerDebug)

import           Config
import           InputHistory
import           Login
import           LastRunState
import           State.Messages
import           TeamSelect
import           Themes
import           TimeUtils (lookupLocalTimeZone)
import           State.Setup.Threads
import           Types
import qualified Zipper as Z

incompleteCredentials :: Config -> ConnectionInfo
incompleteCredentials config = ConnectionInfo hStr (configPort config) uStr pStr
    where
        hStr = maybe "" id $ configHost config
        uStr = maybe "" id $ configUser config
        pStr = case configPass config of
            Just (PasswordString s) -> s
            _                       -> ""

convertLoginExceptions :: IO a -> IO (Either AuthenticationException a)
convertLoginExceptions act =
    (Right <$> act)
        `catch` (\e -> return $ Left $ ResolveError e)
        `catch` (\e -> return $ Left $ ConnectError e)
        `catchIOError` (\e -> return $ Left $ AuthIOError e)
        `catch` (\e -> return $ Left $ OtherAuthError e)

setupState :: Maybe Handle -> Config -> IO ChatState
setupState logFile initialConfig = do
  -- If we don't have enough credentials, ask for them.
  connInfo <- case getCredentials initialConfig of
      Nothing -> interactiveGatherCredentials (incompleteCredentials initialConfig) Nothing
      Just connInfo -> return connInfo

  let setLogger = case logFile of
        Nothing -> id
        Just f  -> \ cd -> cd `withLogger` mmLoggerDebug f

      poolCfg = ConnectionPoolConfig { cpIdleConnTimeout = 60
                                     , cpStripesCount = 1
                                     , cpMaxConnCount = 5
                                     }
      loginLoop cInfo = do
        cd <- fmap setLogger $
                if (configUnsafeUseHTTP initialConfig)
                  then initConnectionDataInsecure (cInfo^.ciHostname)
                         (fromIntegral (cInfo^.ciPort))
                         poolCfg
                  else initConnectionData (cInfo^.ciHostname)
                         (fromIntegral (cInfo^.ciPort))
                         poolCfg

        let login = Login { username = cInfo^.ciUsername
                          , password = cInfo^.ciPassword
                          }
        result <- convertLoginExceptions $ mmLogin cd login

        -- Update the config with the entered settings so that later,
        -- when we offer the option of saving the entered credentials to
        -- disk, we can do so with an updated config.
        let config =
                initialConfig { configUser = Just $ cInfo^.ciUsername
                              , configPass = Just $ PasswordString $ cInfo^.ciPassword
                              , configPort = cInfo^.ciPort
                              , configHost = Just $ cInfo^.ciHostname
                              }

        case result of
            Right (Right (sess, user)) ->
                return (sess, user, cd, config)
            Right (Left e) ->
                interactiveGatherCredentials cInfo (Just $ LoginError e) >>=
                    loginLoop
            Left e ->
                interactiveGatherCredentials cInfo (Just e) >>=
                    loginLoop

  (session, me, cd, config) <- loginLoop connInfo

  teams <- mmGetUsersTeams UserMe session
  when (Seq.null teams) $ do
      putStrLn "Error: your account is not a member of any teams"
      exitFailure

  myTeam <- case configTeam config of
      Nothing -> do
          interactiveTeamSelection $ toList teams
      Just tName -> do
          let matchingTeam = listToMaybe $ filter matches $ toList teams
              matches t = teamName t == tName
          case matchingTeam of
              Nothing -> interactiveTeamSelection (toList teams)
              Just t -> return t

  userStatusLock <- newMVar ()

  userIdSet <- STM.atomically $ STM.newTVar mempty

  slc <- STM.newTChanIO
  wac <- STM.newTChanIO

  prefs <- mmGetUsersPreferences UserMe session
  let userPrefs = setUserPreferences prefs defaultUserPreferences

  let themeName = case configTheme config of
          Nothing -> internalThemeName defaultTheme
          Just t -> t
      baseTheme = internalTheme $ fromMaybe defaultTheme (lookupTheme themeName)

  -- Did the configuration specify a theme customization file? If so,
  -- load it and customize the theme.
  custTheme <- case configThemeCustomizationFile config of
      Nothing -> return baseTheme
      Just path ->
          -- If we have no configuration path (i.e. we used the default
          -- config) then ignore theme customization.
          let pathStr = T.unpack path
          in if isRelative pathStr && isNothing (configAbsPath config)
             then return baseTheme
             else do
                 let absPath = if isRelative pathStr
                               then (dropFileName $ fromJust $ configAbsPath config) </> pathStr
                               else pathStr
                 result <- loadCustomizations absPath baseTheme
                 case result of
                     Left e -> do
                         putStrLn $ "Error loading theme customization from " <> show absPath <> ": " <> e
                         exitFailure
                     Right t -> return t

  requestChan <- STM.atomically STM.newTChan
  eventChan <- newBChan 25

  let cr = ChatResources session cd requestChan eventChan
             slc wac (themeToAttrMap custTheme) userStatusLock
             userIdSet config mempty userPrefs

  initializeState cr myTeam me

initializeState :: ChatResources -> Team -> User -> IO ChatState
initializeState cr myTeam me = do
  let session = getResourceSession cr
      requestChan = cr^.crRequestQueue
      myTId = getId myTeam

  -- Create a predicate to find the last selected channel by reading the
  -- run state file. If unable to read or decode or validate the file, this
  -- predicate is just `isTownSquare`.
  isLastSelectedChannel <- do
    result <- readLastRunState $ teamId myTeam
    case result of
      Right lrs | isValidLastRunState cr me lrs -> return $ \c ->
           channelId c == lrs^.lrsSelectedChannelId
      _ -> return isTownSquare

  -- Get all channels, but filter down to just the one we want to start
  -- in. We get all, rather than requesting by name or ID, because
  -- we don't know whether the server will give us a last-viewed preference.
  -- We first try to find a channel matching with the last selected channel ID,
  -- failing which we look for the Town Square channel by name.
  -- This is not entirely correct since the Town Square channel can be renamed!
  userChans <- mmGetChannelsForUser UserMe myTId session
  let lastSelectedChans = Seq.filter isLastSelectedChannel userChans
      chans = if Seq.null lastSelectedChans
                then Seq.filter isTownSquare userChans
                else lastSelectedChans

  -- Since the only channel we are dealing with is by construction the
  -- last channel, we don't have to consider other cases here:
  msgs <- forM (toList chans) $ \c -> do
      cChannel <- makeClientChannel c
      return (getId c, cChannel)

  tz    <- lookupLocalTimeZone
  hist  <- do
      result <- readHistory
      case result of
          Left _ -> return newHistory
          Right h -> return h

  --------------------------------------------------------------------
  -- Start background worker threads:
  --
  -- * Main async queue worker thread
  startAsyncWorkerThread (cr^.crConfiguration) (cr^.crRequestQueue) (cr^.crEventQueue)

  -- * User status refresher
  startUserRefreshThread (cr^.crUserIdSet) (cr^.crUserStatusLock) session requestChan

  -- * Refresher for users who are typing currently
  when (configShowTypingIndicator (cr^.crConfiguration)) $
    startTypingUsersRefreshThread requestChan

  -- * Timezone change monitor
  startTimezoneMonitorThread tz requestChan

  -- * Subprocess logger
  startSubprocessLoggerThread (cr^.crSubprocessLog) requestChan

  -- * Spell checker and spell check timer, if configured
  spResult <- maybeStartSpellChecker (cr^.crConfiguration) (cr^.crEventQueue)

  -- End thread startup ----------------------------------------------

  let names = mkNames me mempty chans
      chanIds = getChannelIdsInOrder names
      chanZip = Z.fromList chanIds
      startupState =
          StartupStateInfo { startupStateResources      = cr
                           , startupStateChannelZipper  = chanZip
                           , startupStateConnectedUser  = me
                           , startupStateTeam           = myTeam
                           , startupStateTimeZone       = tz
                           , startupStateInitialHistory = hist
                           , startupStateSpellChecker   = spResult
                           , startupStateNames          = names
                           }
      st = newState startupState
             & csChannels %~ flip (foldr (uncurry addChannel)) msgs

  loadFlaggedMessages (cr^.crUserPreferences.userPrefFlaggedPostList) st

  -- Trigger an initial websocket refresh
  writeBChan (cr^.crEventQueue) RefreshWebsocketEvent

  return st
