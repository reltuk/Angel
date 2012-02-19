-- |various utility functions
module Angel.Util (WorkSignal, newWorkSignalIO,
                   waitForWork, notifyWork,
                   sleepSecs, void)
where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar (readTVar, writeTVar)
import Control.Concurrent (threadDelay, forkIO, forkOS)

data CanGo = Go | Pause

-- |a type providing the ability to wait until work is
-- |available and to notify that work is available
newtype WorkSignal = WorkSignal (TVar CanGo)

-- |wait for the WorkSignal to be notified
waitForWork :: WorkSignal -> IO ()
waitForWork (WorkSignal workSig) = atomically $ do
    state <- readTVar workSig
    case state of
        Go -> writeTVar workSig Pause
        Pause -> retry

-- |notify a WorkSignal that there is work
notifyWork :: WorkSignal -> IO ()
notifyWork (WorkSignal workSig) = atomically $ writeTVar workSig $ Go

-- |create a new WorkSignal.  The WorkSignal starts out
-- |with no work being notified.
newWorkSignalIO :: IO WorkSignal
newWorkSignalIO = newTVarIO Pause >>= return.WorkSignal

-- |sleep for `s` seconds in an thread
sleepSecs :: Int -> IO ()
sleepSecs s = threadDelay $ s * 1000000

void :: Monad m => m a -> m ()
void m = m >> return ()
