{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      :  Pact.Types.Continuation
-- Copyright   :  (C) 2019 Stuart Popejoy, Emily Pillmore
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>, Emily Pillmore <emily@kadena.io>
--
-- Pact Continuation data
--
module Pact.Types.Continuation
  ( -- * Types
    PactStep(..)
  , PactContinuation(..)
  , PactExec(..)
  , NestedPactExec(..)
  , Yield(..)
  , Provenance(..)
    -- * Optics
  , peStepCount, peYield, peExecuted, pePactId
  , peStep, peContinuation, peStepHasRollback
  , npeStepCount, npeYield, npeExecuted, npeStep
  , npePactId, npeContinuation, npeNested
  , psStep, psRollback, psPactId, psResume, peNested
  , pcDef, pcArgs
  , yData, yProvenance, ySourceChain
  , pTargetChainId, pModuleHash
  , toNestedPactExec
  , fromNestedPactExec
  ) where

import GHC.Generics (Generic)

import Control.DeepSeq (NFData)
import Control.Lens hiding ((.=))

import Data.Aeson
import Data.Map.Strict(Map)
import Data.Maybe(fromMaybe)
import qualified Data.Map.Strict as Map

import Test.QuickCheck

import Pact.Types.ChainId (ChainId)
import Pact.Types.PactValue
import Pact.Types.Pretty
import Pact.Types.SizeOf
import Pact.Types.Term
import Pact.Types.Util (lensyToJSON, lensyParseJSON)


-- | Provenance datatype contains all of the necessary
-- data to 'endorse' a yield object.
--
data Provenance = Provenance
  { _pTargetChainId :: !ChainId
    -- ^ the target chain id for the endorsement
  , _pModuleHash :: ModuleHash
    -- ^ a hash of current containing module
  } deriving (Eq, Show, Generic)

instance Arbitrary Provenance where
  arbitrary = Provenance <$> arbitrary <*> arbitrary

instance Pretty Provenance where
  pretty (Provenance c h) = "(chain = \"" <> pretty c <> "\" hash=\"" <> pretty h <> "\")"

instance SizeOf Provenance where
  sizeOf (Provenance chainId modHash) =
    (constructorCost 2) + (sizeOf chainId) + (sizeOf modHash)

instance NFData Provenance
instance ToJSON Provenance where toJSON = lensyToJSON 2
instance FromJSON Provenance where parseJSON = lensyParseJSON 2

-- | The type of a set of yielded values of a pact step.
--
data Yield = Yield
  { _yData :: !(ObjectMap PactValue)
    -- ^ Yield data from the pact continuation
  , _yProvenance :: !(Maybe Provenance)
    -- ^ Provenance data
  , _ySourceChain :: !(Maybe ChainId)
  } deriving (Eq, Show, Generic)

instance Arbitrary Yield where
  arbitrary = Yield <$> (genPactValueObjectMap RecurseTwice) <*> frequency
    [ (1, pure Nothing)
    , (4, Just <$> arbitrary) ] <*> pure Nothing

instance NFData Yield
instance ToJSON Yield where
  toJSON Yield{..} = object $
      [ "data" .= _yData
      , "provenance" .= _yProvenance ] ++
      maybe [] (\c -> [ "source" .= c ]) _ySourceChain
instance FromJSON Yield where
  parseJSON = withObject "Yield" $ \o ->
    Yield <$> o .: "data" <*> o .: "provenance" <*> o .:? "source"

instance SizeOf Yield where
  sizeOf (Yield dataYield prov _) =
    (constructorCost 2) + (sizeOf dataYield) + (sizeOf prov)

-- | Environment setup for pact execution, from ContMsg request.
--
data PactStep = PactStep
  { _psStep :: !Int
    -- ^ intended step to execute
  , _psRollback :: !Bool
    -- ^ rollback
  , _psPactId :: !PactId
    -- ^ pact id
  , _psResume :: !(Maybe Yield)
    -- ^ resume value. Note that this is only set in Repl tests and in private use cases;
    -- in all other cases resume value comes out of PactExec.
} deriving (Eq,Show)

instance Pretty PactStep where
  pretty = viaShow

-- | The type of pact continuations (i.e. defpact)
--
data PactContinuation = PactContinuation
  { _pcDef :: Name
  , _pcArgs :: [PactValue]
  } deriving (Eq, Show, Generic)

instance Pretty PactContinuation where
  pretty (PactContinuation d as) = parensSep (pretty d:map pretty as)

instance NFData PactContinuation
instance ToJSON PactContinuation where toJSON = lensyToJSON 3
instance FromJSON PactContinuation where parseJSON = lensyParseJSON 3

-- | Result of evaluation of a 'defpact'.
--
data PactExec = PactExec
  { _peStepCount :: Int
    -- ^ Count of steps in pact (discovered when code is executed)
  , _peYield :: !(Maybe Yield)
    -- ^ Yield value if invoked
  , _peExecuted :: Maybe Bool
    -- ^ Only populated for private pacts, indicates if step was executed or skipped.
  , _peStep :: Int
    -- ^ Step that was executed or skipped
  , _pePactId :: PactId
    -- ^ Pact id. On a new pact invocation, is copied from tx id.
  , _peContinuation :: PactContinuation
    -- ^ Strict (in arguments) application of pact, for future step invocations.
  , _peStepHasRollback :: !Bool
    -- ^ Track whether a current step has a rollback
  , _peNested :: Map PactId NestedPactExec
    -- ^ Track whether a current step has nested defpact evaluation results
  } deriving (Eq, Show, Generic)

instance NFData PactExec
instance ToJSON PactExec where
  toJSON PactExec{..} = object $
    [ "executed" .= _peExecuted
    , "pactId" .= _pePactId
    , "stepHasRollback" .= _peStepHasRollback
    , "step" .= _peStep
    , "yield" .= _peYield
    , "continuation" .= _peContinuation
    , "stepCount" .= _peStepCount
    ] ++ [ "nested" .= _peNested | not (Map.null _peNested)]

instance FromJSON PactExec where
  parseJSON = withObject "PactExec" $ \o ->
    PactExec
      <$> o .: "stepCount"
      <*> o .: "yield"
      <*> o .: "executed"
      <*> o .: "step"
      <*> o .: "pactId"
      <*> o .: "continuation"
      <*> o .: "stepHasRollback"
      <*> (fromMaybe mempty <$> o .:? "nested")

instance Pretty PactExec where pretty = viaShow

data NestedPactExec = NestedPactExec
  { _npeStepCount :: Int
    -- ^ Count of steps in pact (discovered when code is executed)
  , _npeYield :: !(Maybe Yield)
    -- ^ Yield value if invoked
  , _npeExecuted :: Maybe Bool
    -- ^ Only populated for private pacts, indicates if step was executed or skipped.
  , _npeStep :: Int
    -- ^ Step that was executed or skipped
  , _npePactId :: PactId
    -- ^ Pact id. On a new pact invocation, is copied from tx id.
  , _npeContinuation :: PactContinuation
    -- ^ Strict (in arguments) application of pact, for future step invocations.
  , _npeNested :: Map PactId NestedPactExec
    -- ^ Track whether a current step has nested defpact evaluation results
  } deriving (Eq, Show, Generic)

toNestedPactExec :: PactExec -> NestedPactExec
toNestedPactExec (PactExec stepCount yield exec step pid cont _ nested) =
  NestedPactExec stepCount yield exec step pid cont nested

fromNestedPactExec :: Bool -> NestedPactExec -> PactExec
fromNestedPactExec rollback (NestedPactExec stepCount yield exec step pid cont nested) =
  PactExec stepCount yield exec step pid cont rollback nested


instance ToJSON NestedPactExec where
  toJSON NestedPactExec{..} = object $
    [ "executed" .= _npeExecuted
    , "pactId" .= _npePactId
    , "yield" .= _npeYield
    , "step" .= _npeStep
    , "continuation" .= _npeContinuation
    , "stepCount" .= _npeStepCount
    , "nested" .= _npeNested
    ]
instance FromJSON NestedPactExec where
  parseJSON = withObject "NestedPactExec" $ \o ->
    NestedPactExec
      <$> o .: "stepCount"
      <*> o .: "yield"
      <*> o .: "executed"
      <*> o .: "step"
      <*> o .: "pactId"
      <*> o .: "continuation"
      <*> o .: "nested"
instance NFData NestedPactExec
instance Pretty NestedPactExec where pretty = viaShow


makeLenses ''PactExec
makeLenses ''NestedPactExec
makeLenses ''PactStep
makeLenses ''PactContinuation
makeLenses ''Yield
makeLenses ''Provenance
