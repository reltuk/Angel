module Angel.Job where

import Data.String.Utils (split, strip)
import Data.Maybe (isJust, fromJust)
import System.Process (createProcess, proc, waitForProcess, ProcessHandle)
import System.Process (terminateProcess, CreateProcess(..), StdStream(..))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar (readTVar, writeTVar)
import qualified Data.Map as M
import Control.Monad (unless, when, forever)
import Control.Exception (try, bracket, SomeException)

import Angel.Log (logger)
import Angel.Data
import Angel.Util (WorkSignal, waitForWork, notifyWork, sleepSecs, void)
import Angel.Files (getFile)

-- |launch the program specified by `id`, opening (and closing) the
-- |appropriate fds for logging.  When the process dies, either b/c it was
-- |killed by a monitor, killed by a system user, or ended execution naturally,
-- |re-examine the desired run config to determine whether to re-run it.  if so,
-- |tail call.
supervise sharedGroupConfig id = do
    let log = logger $ "- program: " ++ id ++ " -"
    log "START"
    cfg <- atomically $ readTVar sharedGroupConfig
    let my_specM = M.lookup id (spec cfg)
    case my_specM of
        Nothing -> log "QUIT (missing from config on restart)"
        Just my_spec ->
            do fileResp <- try $ makeFiles my_spec cfg :: IO (Either SomeException (StdStream, StdStream))
               case fileResp of
                 Right (attachOut, attachErr) -> do
                   let (cmd, args) = cmdSplit $ exec my_spec

                   (_, _, _, p) <- createProcess (proc cmd args){
                   std_out = attachOut,
                   std_err = attachErr,
                   cwd = workingDir my_spec
                   }

                   atomically $ updateRunningPid sharedGroupConfig my_spec id (Just p)
                   log "RUNNING"
                   waitForProcess p
                   log "ENDED"
                   atomically $ updateRunningPid sharedGroupConfig my_spec id (Nothing)

                   cfg <- atomically $ readTVar sharedGroupConfig
                   if M.notMember id (spec cfg)
                     then log "QUIT"
                     else waitAndRestart log my_spec
                 Left e -> do log $ "error creating log files: " ++ show e
                              waitAndRestart log my_spec
    where
        cmdSplit fullcmd = (head parts, tail parts)
            where parts = (filter (/="") . map strip . split " ") fullcmd

        makeFiles my_spec cfg = do
            attachOut <- case stdout my_spec of
                ""    -> return Inherit
                other -> UseHandle `fmap` getFile other cfg

            attachErr <- case stderr my_spec of
                ""    -> return Inherit
                other -> UseHandle `fmap` getFile other cfg
            return $ (attachOut, attachErr)

        waitAndRestart log my_spec = do
            log "WAITING"
            sleepSecs $ delay my_spec
            log "RESTART"
            supervise sharedGroupConfig id

updateRunningPid sharedGroupConfig my_spec id mpid = do
    wcfg <- readTVar sharedGroupConfig
    writeTVar sharedGroupConfig wcfg{
      running=M.insert id (my_spec, mpid) (running wcfg)
    }

updateRunningPidCurrent sharedGroupConfig id mpid = do
    wcfg <- readTVar sharedGroupConfig
    let my_spec = M.findWithDefault defaultProgram id (spec wcfg)
    updateRunningPid sharedGroupConfig my_spec id mpid

deleteRunning sharedGroupConfig id = do
    wcfg <- readTVar sharedGroupConfig
    writeTVar sharedGroupConfig wcfg{
        running=M.delete id (running wcfg)
    }

-- |send a TERM signal to all provided process handles
killProcesses :: [ProcessHandle] -> IO ()
killProcesses pids = mapM_ terminateProcess pids

-- |fire up new supervisors for new program ids.  This function first inserts
-- |a dummy value for the program id into the shared state, and then spawns
-- |the supervise thread.  When the supervise thread terminates, it removes
-- |the value from the shared state.  It also removes the value from the shared
-- |state if forking the supervise thread fails.
startProcesses :: TVar GroupConfig -> [String] -> IO ()
startProcesses sharedGroupConfig starts = mapM_ spawnWatcher starts
    where
        spawnWatcher id = do
            atomically $ updateRunningPidCurrent sharedGroupConfig id (Nothing)
            catch (void $ forkIO $ do try (supervise sharedGroupConfig id) :: IO (Either SomeException ())
                                      atomically $ deleteRunning sharedGroupConfig id)
                  (\e -> atomically $ deleteRunning sharedGroupConfig id)

-- |diff the requested config against the actual run state, and
-- |do any start/kill action necessary
startSyncSupervisorsThread :: WorkSignal -> TVar GroupConfig -> IO ()
startSyncSupervisorsThread workSig sharedGroupConfig = forever $ do
   let log = logger "process-monitor"
   cfg <- atomically $ readTVar sharedGroupConfig
   let kills = mustKill cfg
   let starts = mustStart cfg
   when (length kills > 0 || length starts > 0) $ log (
         "Must kill=" ++ (show $ length kills)
                ++ ", must start=" ++ (show $ length starts))
   killProcesses kills
   startProcesses sharedGroupConfig starts
   waitForWork workSig
    where
        mustKill cfg = map (fromJust . snd . snd) $ filter (runningAndDifferent $ spec cfg) $ M.assocs (running cfg)
        runningAndDifferent spec (id, (pg, pid)) = (isJust pid && (M.notMember id spec
                                           || M.findWithDefault defaultProgram id spec `cmp` pg))
            where cmp one two = one /= two

        mustStart cfg = map fst $ filter (isNew $ running cfg) $ M.assocs (spec cfg)
        isNew running (id, pg) = M.notMember id running

-- |periodically run the supervisor sync independent of config reload,
-- |just in case state gets funky b/c of theoretically possible timing
-- |issues on reload
startPollStaleThread :: WorkSignal -> IO ()
startPollStaleThread notifySig = forever $ sleepSecs 10 >> notifyWork notifySig
