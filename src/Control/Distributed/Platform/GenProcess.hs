{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Distributed.Platform.GenProcess where

-- TODO: define API and hide internals...

import qualified Control.Distributed.Process              as BaseProcess
import           Control.Distributed.Process.Serializable
import qualified Control.Monad.State                      as ST (StateT, get,
                                                                 lift, modify,
                                                                 put, runStateT)
import           Data.Binary
import           Data.DeriveTH
import           Data.Typeable                            (Typeable)
import           Prelude                                  hiding (init)

type Name = String

data Recipient a = SendToPid BaseProcess.ProcessId |
                   SendToPort (BaseProcess.SendPort a)

-- | Defines the time unit for a Timeout value
data TimeUnit = Hours | Minutes | Seconds | Millis
    deriving (Typeable)
$(derive makeBinary ''TimeUnit)

data TimeInterval = Interval TimeUnit Int
    deriving (Typeable)
$(derive makeBinary ''TimeInterval)

-- | Defines a Timeout value (and unit of measure) or
--   sets it to infinity (no timeout)
data Timeout = Timeout TimeInterval | Infinity
    deriving (Typeable)
$(derive makeBinary ''Timeout)

-- | Initialize handler result
-- TODO: handle state
data InitResult =
    InitOk Timeout
  | InitStop String

-- | Terminate reason
data TerminateReason =
    TerminateNormal
  | TerminateShutdown
  | TerminateReason String
    deriving (Show, Typeable)
$(derive makeBinary ''TerminateReason)

data ReplyTo = ReplyTo BaseProcess.ProcessId | None
    deriving (Typeable, Show)
$(derive makeBinary ''ReplyTo)

-- | The result of a call
data ProcessAction =
    ProcessContinue
  | ProcessTimeout Timeout
  | ProcessReply ReplyTo
  | ProcessStop String
    deriving (Typeable)
$(derive makeBinary ''ProcessAction)

type Process s = ST.StateT s BaseProcess.Process

-- | Handlers
type InitHandler      s   = Process s InitResult
type TerminateHandler s   = TerminateReason -> Process s ()
type RequestHandler   s m = m -> Process s ProcessAction

-- | Contains the actual payload and possibly additional routing metadata
data Message a = Message a | Request BaseProcess.ProcessId a
    deriving (Typeable)
$(derive makeBinary ''Message)

-- | Dispatcher that knows how to dispatch messages to a handler
data Dispatcher s =
  forall a . (Serializable a) =>
    Dispatch    { dispatch  :: s -> Message a ->
                               BaseProcess.Process (s, Maybe TerminateReason) } |
  forall a . (Serializable a) =>
    DispatchIf  { dispatch  :: s -> Message a ->
                               BaseProcess.Process (s, Maybe TerminateReason),
                  condition :: s -> Message a -> Bool }

-- dispatching to implementation callbacks

-- | Matches messages using a dispatcher
class Dispatchable d where
    matchMessage :: s -> d s -> BaseProcess.Match (s, Maybe TerminateReason)

-- | Matches messages to a MessageDispatcher
instance Dispatchable Dispatcher where
  matchMessage s (Dispatch   d  ) = BaseProcess.match (d s)
  matchMessage s (DispatchIf d c) = BaseProcess.matchIf (c s) (d s)


data Behaviour s = Behaviour {
    initHandler      :: InitHandler s        -- ^ initialization handler
  , dispatchers      :: [Dispatcher s]
  , terminateHandler :: TerminateHandler s    -- ^ termination handler
    }

-- | Management message
-- TODO is there a std way of terminating a process from another process?
data Termination = Terminate TerminateReason
    deriving (Show, Typeable)
$(derive makeBinary ''Termination)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a new server and return it's id
-- start :: Behaviour s -> Process ProcessId
-- start handlers = spawnLocal $ runProcess handlers

intervalToMillis :: TimeInterval -> Int
intervalToMillis (Interval u v) = timeToMs u v

timeToMs :: TimeUnit -> Int -> Int
timeToMs Millis  ms   = ms
timeToMs Seconds sec  = sec * 1000
timeToMs Minutes mins = (mins * 60) * 1000
timeToMs Hours   hrs  = ((hrs * 60) * 60) * 1000

reply :: (Serializable m) => ReplyTo -> m -> BaseProcess.Process ()
reply (ReplyTo pid) m = BaseProcess.send pid m
reply _             _ = return ()

replyVia :: (Serializable m) => BaseProcess.SendPort m -> m ->
                                BaseProcess.Process ()
replyVia p m = BaseProcess.sendChan p m

-- | Given a state, behaviour specificiation and spawn function,
-- starts a new server and return it's id. The spawn function is typically
-- one taken from "Control.Distributed.Process".
-- see 'Control.Distributed.Process.spawn'
--     'Control.Distributed.Process.spawnLocal' 
--     'Control.Distributed.Process.spawnLink'
--     'Control.Distributed.Process.spawnMonitor'
--     'Control.Distributed.Process.spawnSupervised' 
start ::
  s -> Behaviour s ->
  (BaseProcess.Process () -> BaseProcess.Process BaseProcess.ProcessId) ->
  BaseProcess.Process BaseProcess.ProcessId
start state handlers spawn = spawn $ do
  _ <- ST.runStateT (runProc handlers) state
  return ()

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | Get the server state
getState :: Process s s
getState = ST.get

-- | Put the server state
putState :: s -> Process s ()
putState = ST.put

-- | Modify the server state
modifyState :: (s -> s) -> Process s ()
modifyState = ST.modify

-- | server process
runProc :: Behaviour s -> Process s ()
runProc s = do
    ir <- init s
    tr <- case ir of
            InitOk to -> do
              trace $ "Server ready to receive messages!"
              loop s to
            InitStop r -> return (TerminateReason r)
    terminate s tr

-- | initialize server
init :: Behaviour s -> Process s InitResult
init s = do
    trace $ "Server initializing ... "
    ir <- initHandler s
    return ir

loop :: Behaviour s -> Timeout -> Process s TerminateReason
loop s t = do
    mayMsg <- processReceive (dispatchers s) t
    case mayMsg of
        Just r -> return r
        Nothing -> loop s t

processReceive :: [Dispatcher s] -> Timeout -> Process s (Maybe TerminateReason)
processReceive ds timeout = do
    s <- getState
    let ms = map (matchMessage s) ds
    -- TODO: should we drain the message queue an avoid selective receive here?
    case timeout of
        Infinity -> do
            (s', r) <- ST.lift $ BaseProcess.receiveWait ms
            putState s'
            return r
        Timeout t -> do
            result <- ST.lift $ BaseProcess.receiveTimeout (intervalToMillis t) ms
            case result of
                Just (s', r) -> do
                  putState s'
                  return r
                Nothing -> do
                  trace "Receive timed out ..."
                  return $ Just (TerminateReason "Receive timed out")

terminate :: Behaviour s -> TerminateReason -> Process s ()
terminate localServer reason = do
    trace $ "Server terminating: " ++ show reason
    (terminateHandler localServer) reason

-- | Log a trace message using the underlying Process's say
trace :: String -> Process s ()
trace msg = ST.lift . BaseProcess.say $ msg

-- data Upgrade = ???
-- TODO: can we use 'Static (SerializableDict a)' to pass a Behaviour spec to
-- a remote pid? if so then we can do hot server-code loading quite easily...

