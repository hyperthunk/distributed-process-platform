{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Main where

import Prelude hiding (catch)
import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.DeriveTH
import Control.Monad (forever)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  , withMVar
  )
-- import Control.Applicative ((<$>), (<*>), pure, (<|>))
import qualified Network.Transport as NT ()
import Network.Transport.TCP
  ( createTransport
  , defaultTCPParameters
  )
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types()
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Platform.Timer

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Test.HUnit.Base (assertBool)

type TestResult a = MVar a

data Ping = Ping
    deriving (Typeable)
$(derive makeBinary ''Ping)

testSendAfter :: TestResult Bool -> Process ()
testSendAfter result =  do
  let delay = seconds 1
  pid <- getSelfPid
  _ <- sendAfter delay pid Ping
  hdInbox <- receiveTimeout (intervalToMs delay * 2) [
                                 match (\m@(Ping) -> return m) ]
  case hdInbox of
      Just Ping -> stash result True
      Nothing   -> stash result False

testRunAfter :: TestResult Bool -> Process ()
testRunAfter result = do
  let delay = seconds 2  

  parentPid <- getSelfPid
  _ <- spawnLocal $ do
    _ <- runAfter delay $ do { send parentPid Ping }
    return ()

  msg <- expectTimeout (intervalToMs delay * 2)
  case msg of
      Just Ping -> stash result True
      Nothing   -> stash result False
  return ()

testCancelTimer :: TestResult Bool -> Process ()
testCancelTimer result = do
  let delay = milliseconds 200
  
  _ <- spawnLocal $ do
      pid <- periodically delay noop
      
      sleep $ seconds 1
      
      ref <- monitor pid
      cancelTimer pid
      
      ProcessMonitorNotification ref' pid' DiedNormal <- expect
      stash result $ ref == ref' && pid == pid'
  return ()

testPeriodicSend :: TestResult Bool -> Process ()
testPeriodicSend result = do
    let delay = milliseconds 100
    self <- getSelfPid
    ref <- ticker delay self
    listener 0 ref
    liftIO $ putMVar result True
  where listener :: Int -> TimerRef -> Process ()
        listener n tRef | n > 10    = cancelTimer tRef
                        | otherwise = waitOne >> listener (n + 1) tRef  
        waitOne :: Process ()
        waitOne = do
            Tick <- expect
            return ()
--------------------------------------------------------------------------------
-- Plumbing                                                                   --
--------------------------------------------------------------------------------

delayedAssertion :: (Eq a) => String -> LocalNode -> a ->
                    (TestResult a -> Process ()) -> Assertion
delayedAssertion note localNode expected testProc = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ testProc result
  assertComplete note result expected

assertComplete :: (Eq a) => String -> MVar a -> a -> IO ()
assertComplete msg mv a = do
    b <- takeMVar mv
    assertBool msg (a == b)

noop :: Process ()
noop = say "tick\n"

stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Timer Send" [
        testCase "testSendAfter"    (delayedAssertion
                                     "expected Ping within 1 second"
                                     localNode
                                     True
                                     testSendAfter)
      , testCase "testRunAfter"     (delayedAssertion
                                     "expecting run (which pings parent) within 2 seconds"
                                     localNode
                                     True
                                     testRunAfter)
      , testCase "testCancelTimer"  (delayedAssertion
                                     "expected cancelTimer to exit the timer process normally"
                                     localNode
                                     True
                                     testCancelTimer)
      , testCase "testPeriodicSend" (delayedAssertion
                                     "expected ten Ticks to have been sent before exiting"
                                     localNode
                                     True
                                     testPeriodicSend)
      ]
  ]

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  localNode <- newLocalNode transport initRemoteTable
  defaultMain (tests localNode)
