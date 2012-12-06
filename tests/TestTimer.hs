{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Main where

import Prelude hiding (catch)
import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.DeriveTH
import Data.Foldable (forM_)
import Control.Concurrent (forkIO, threadDelay, myThreadId, throwTo, ThreadId)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  )
import Control.Monad (replicateM_, replicateM, forever)
import Control.Exception (SomeException, throwIO)
import qualified Control.Exception as Ex (catch)
import Control.Applicative ((<$>), (<*>), pure, (<|>))
import qualified Network.Transport as NT (Transport, closeEndPoint)
import Network.Socket (sClose)
import Network.Transport.TCP
  ( createTransport
  , defaultTCPParameters
  )
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
  ( NodeId(nodeAddress)
  , LocalNode(localEndPoint)
  , RegisterReply(..)
  )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)

import Control.Distributed.Platform.Timer

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Test.HUnit.Base (assertBool)

data Ping = Ping
    deriving (Typeable)
$(derive makeBinary ''Ping)

testSendAfter :: LocalNode -> Assertion
testSendAfter localNode = do
  received <- newEmptyMVar
  _ <- forkProcess localNode $ do
    let delay = seconds 1
    pid <- getSelfPid
    _ <- sendAfter delay pid Ping
    hdInbox <- receiveTimeout (intervalToMs delay * 2) [
                  match (\m@(Ping) -> return m) ]
    case hdInbox of
        Just Ping -> stash received True
        Nothing   -> stash received False

  assertComplete "expected Ping within 1 second" received

testRunAfter :: LocalNode -> Assertion
testRunAfter localNode = do
  result <- newEmptyMVar
  let delay = seconds 2
  
  parentPid <- forkProcess localNode $ do
    msg <- expectTimeout (intervalToMs delay * 2)
    case msg of
        Just Ping -> stash result True
        Nothing   -> stash result False
  
  _ <- forkProcess localNode $ do
    _ <- runAfter delay $ do { send parentPid Ping }
    return ()
  
  assertComplete "expecting run (which pings parent) within 2 seconds" result

testCancelTimer :: LocalNode -> Assertion
testCancelTimer localNode = do
  result <- newEmptyMVar
  let delay = seconds 2
  
  _ <- forkProcess localNode $ do
      pid <- periodically delay noop
      ref <- monitor pid
      cancelTimer pid
      
      ProcessMonitorNotification ref' pid' DiedNormal <- expect
      liftIO $ putMVar result $ ref == ref' && pid == pid'

  assertComplete "expected cancelTimer to exit the timer process normally" result

--------------------------------------------------------------------------------
-- Plumbing                                                                   --
--------------------------------------------------------------------------------

assertComplete :: String -> MVar Bool -> IO ()
assertComplete msg mv = do
    b <- takeMVar mv
    assertBool msg b

noop :: Process ()
noop = say "tick\n"

stash :: MVar a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Timer Send" [
        testCase "testSendAfter"   (testSendAfter   localNode)
      , testCase "testRunAfter"    (testRunAfter    localNode)
      , testCase "testCancelTimer" (testCancelTimer localNode)
      ]
  ]

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  localNode <- newLocalNode transport initRemoteTable
  defaultMain (tests localNode)
