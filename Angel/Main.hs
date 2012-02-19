module Main where 

import Control.Concurrent (threadDelay, forkIO, forkOS)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar (readTVar, writeTVar)
import Control.Concurrent.STM.TChan (newTChan)
import Control.Monad (unless, when, forever)
import System.Environment (getArgs)
import System.Posix.Signals
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

import qualified Data.Map as M

import Angel.Log (logger)
import Angel.Config (monitorConfig)
import Angel.Data (GroupConfig(..))
import Angel.Job (pollStale, syncSupervisors)
import Angel.Files (startFileManager)
import Angel.Util (newWorkSignalIO, notifyWork)

main = do 
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    let log = logger "main" 
    log "Angel started"
    args <- getArgs

    -- Exactly one argument required for the `angel` executable
    unless (length args == 1) $ error "exactly one argument required: config file"
    let configPath = head args
    log $ "Using config file: " ++ configPath

    -- Create the TVar that represents the "global state" of running applications
    -- and applications that _should_ be running
    fileReqChan <- atomically $ newTChan
    sharedGroupConfig <- newTVarIO $ GroupConfig M.empty M.empty fileReqChan

    -- The wake signal, set by the HUP handler to wake the monitor loop
    configWorkSig <- newWorkSignalIO
    installHandler sigHUP (Catch $ notifyWork configWorkSig) Nothing

    forkIO $ startFileManager fileReqChan

    -- The sync config signal, used by both pollStale and
    -- monitorConfig to notify the syncSupervisors thread
    -- that it is time to do work.
    syncSig <- newWorkSignalIO

    -- Start the syncSupervisors thread.
    forkIO $ forever $ syncSupervisors syncSig sharedGroupConfig

    -- Fork off an ongoing state monitor to watch for inconsistent state
    forkIO $ pollStale syncSig

    -- Finally, run the config load/monitor thread
    runInUnboundThread $ forever $ monitorConfig configPath sharedGroupConfig configWorkSig syncSig
