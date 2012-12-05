{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Control.Distributed.Platform.Timer (
    TimerRef
  , TimeInterval(..)
  , TimeUnit(..)
  , Tick(Tick)
  , sendAfter
  , runAfter
  , startTimer
  , ticker
  , periodically
  , cancelTimer
  , flushTimer
  , intervalToMs
  , timeToMs
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Platform.Internal.Types
import Data.Binary
import Data.DeriveTH
import Data.Typeable                               (Typeable)
import Prelude                                     hiding (init)

-- | an opaque reference to a timer
type TimerRef = ProcessId

-- | cancellation message sent to timers
data Cancellation = Cancellation
    deriving (Typeable)
$(derive makeBinary ''Cancellation)

data Tick = Tick
    deriving (Typeable)
$(derive makeBinary ''Tick)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | converts the supplied TimeInterval to milliseconds
intervalToMs :: TimeInterval -> Int
intervalToMs (Interval u v) = timeToMs u v

-- TODO: timeToMs is not exactly efficient and we need to scale it up to
--       deal with days, months, years, etc

-- | converts the supplied TimeUnit to milliseconds
timeToMs :: TimeUnit -> Int -> Int
timeToMs Millis  ms   = ms
timeToMs Seconds sec  = sec * 1000
timeToMs Minutes mins = (mins * 60) * 1000
timeToMs Hours   hrs  = ((hrs * 60) * 60) * 1000

-- | starts a timer which sends the supplied message to the destination process
-- after the specified time interval.
sendAfter :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
sendAfter t pid msg = spawnLocal $ runTimer t (sender pid msg) stopTimer

-- | runs the supplied process action(s) after `t' has elapsed 
runAfter :: TimeInterval -> Process () -> Process TimerRef
runAfter t p = spawnLocal $ runTimer t p stopTimer   

-- | starts a timer that repeatedly sends the supplied message to the destination
-- process each time the specified time interval elapses. To stop messages from
-- being sent in future, cancelTimer can be called.
startTimer :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
startTimer t pid msg = spawnLocal $ runTimer t (sender pid msg) restartTimer
  where restartTimer = runTimer t (sender pid msg) restartTimer

-- | runs the supplied process action(s) repeatedly at intervals of `t'
periodically :: TimeInterval -> Process () -> Process TimerRef
periodically t p = spawnLocal $ runTimer t p restartTimer
  where restartTimer = runTimer t p restartTimer

-- | cancel a running timer. Note: Cancelling a timer does not guarantee that
-- a timer's messages are prevented from being delivered to the target process.
cancelTimer :: TimerRef -> Process ()
cancelTimer = (flip send) Cancellation

-- | cancels a running timer and flushes any viable timer messages from the
-- process' message queue. This function should only be called by the process
-- expecting to receive the timer's messages!
flushTimer :: (Serializable a, Eq a) => TimerRef -> a -> Process () 
flushTimer ref ignore = do
    cancelTimer ref
    _ <- receiveTimeout 1 [
                matchIf (\x -> x == ignore)
                        (\_ -> return ()) ]
    return ()

-- | sets up a timer that sends `Tick' repeatedly at intervals of `t'
ticker :: TimeInterval -> ProcessId -> Process TimerRef
ticker t pid = startTimer t pid Tick

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- runs the timer process
runTimer :: TimeInterval -> Process () -> Process () -> Process ()
runTimer t proc onCancel = do
    cancel <- expectTimeout (intervalToMs t)
    case cancel of
        Nothing           -> proc
        Just Cancellation -> onCancel

-- exit the timer process normally
stopTimer :: Process ()
stopTimer = return ()

-- create a 'sender' action for dispatching `msg' to `pid'
sender :: (Serializable a) => ProcessId -> a -> Process ()
sender pid msg = do { send pid msg }
