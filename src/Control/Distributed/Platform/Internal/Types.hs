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

-- | Types used throughout the Cloud Haskell framework
--
module Control.Distributed.Platform.Internal.Types (
    TimeUnit(..)
  , TimeInterval(..)
  , Timeout(..) 
  ) where

import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Prelude       hiding (init)

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
