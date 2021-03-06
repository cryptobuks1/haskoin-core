{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-|
Module      : Network.Haskoin.Transaction.Segwit
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Types to represent segregated witness data and auxilliary functions to
manipulate it.  See [BIP 141](https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki)
and [BIP 143](https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki) for
details.
-}
module Network.Haskoin.Transaction.Segwit
    ( WitnessProgram (..)
    , WitnessProgramPKH (..)
    , WitnessProgramSH (..)
    , isSegwit

    , viewWitnessProgram
    , decodeWitnessInput

    , calcWitnessProgram
    , simpleInputStack
    , toWitnessStack
    ) where

import           Data.ByteString                    (ByteString)
import qualified Data.Serialize                     as S
import           Network.Haskoin.Constants          (Network)
import           Network.Haskoin.Keys.Common        (PubKeyI)
import           Network.Haskoin.Script.Common      (Script (..),
                                                     ScriptOutput (..),
                                                     decodeOutput, encodeOutput)
import           Network.Haskoin.Script.SigHash     (TxSignature (..),
                                                     decodeTxSig, encodeTxSig)
import           Network.Haskoin.Script.Standard    (ScriptInput (..),
                                                     SimpleInput (..))
import           Network.Haskoin.Transaction.Common (WitnessStack)

-- | Test if a 'ScriptOutput' is P2WPKH or P2WSH
--
-- @since 0.11.0.0
isSegwit :: ScriptOutput -> Bool
isSegwit = \case
    PayWitnessPKHash{}     -> True
    PayWitnessScriptHash{} -> True
    _                      -> False

-- | High level represenation of a (v0) witness program
--
-- @since 0.11.0.0
data WitnessProgram = P2WPKH WitnessProgramPKH | P2WSH WitnessProgramSH | EmptyWitnessProgram
    deriving (Eq, Show)

-- | Encode a witness program
--
-- @since 0.11.0.0
toWitnessStack :: WitnessProgram -> WitnessStack
toWitnessStack = \case
    P2WPKH (WitnessProgramPKH sig key) -> [encodeTxSig sig, S.encode key]
    P2WSH (WitnessProgramSH stack scr) -> stack <> [S.encode scr]
    EmptyWitnessProgram                -> mempty

-- | High level representation of a P2WPKH witness
--
-- @since 0.11.0.0
data WitnessProgramPKH = WitnessProgramPKH
    { witnessSignature :: !TxSignature
    , witnessPubKey    :: !PubKeyI
    } deriving (Eq, Show)

-- | High-level representation of a P2WSH witness
--
-- @since 0.11.0.0
data WitnessProgramSH = WitnessProgramSH
    { witnessScriptHashStack  :: ![ByteString]
    , witnessScriptHashScript :: !Script
    } deriving (Eq, Show)

-- | Calculate the witness program from the transaction data
--
-- @since 0.11.0.0
viewWitnessProgram :: Network -> ScriptOutput -> WitnessStack -> Either String WitnessProgram
viewWitnessProgram net so witness = case so of
    PayWitnessPKHash _ | length witness == 2 -> do
        sig    <- decodeTxSig net $ head witness
        pubkey <- S.decode $ witness !! 1
        return . P2WPKH $ WitnessProgramPKH sig pubkey
    PayWitnessScriptHash _ | not (null witness) -> do
        redeemScript <- S.decode $ last witness
        return . P2WSH $ WitnessProgramSH (init witness) redeemScript
    _ | null witness -> return EmptyWitnessProgram
      | otherwise    -> Left "viewWitnessProgram: Invalid witness program"

-- | Analyze the witness, trying to match it with standard input structures
--
-- @since 0.11.0.0
decodeWitnessInput :: Network -> WitnessProgram -> Either String (Maybe ScriptOutput, SimpleInput)
decodeWitnessInput net = \case
    P2WPKH (WitnessProgramPKH sig key) -> return (Nothing, SpendPKHash sig key)
    P2WSH (WitnessProgramSH st scr) -> do
        so <- decodeOutput scr
        fmap (Just so, ) $ case (so, st) of
            (PayPK k, [sigBS]) ->
                SpendPK <$> decodeTxSig net sigBS
            (PayPKHash h, [sigBS, keyBS]) ->
                SpendPKHash <$> decodeTxSig net sigBS <*> S.decode keyBS
            (PayMulSig ps r, "" : sigsBS) ->
                SpendMulSig <$> traverse (decodeTxSig net) sigsBS
            _ -> Left "decodeWitnessInput: Non-standard script output"
    EmptyWitnessProgram -> Left "decodeWitnessInput: Empty witness program"

-- | Create the witness program for a standard input
--
-- @since 0.11.0.0
calcWitnessProgram :: ScriptOutput -> ScriptInput -> Either String WitnessProgram
calcWitnessProgram so si = case (so, si) of
    (PayWitnessPKHash{}, RegularInput (SpendPKHash sig pk)) -> p2wpkh sig pk
    (PayScriptHash{}, RegularInput (SpendPKHash sig pk))    -> p2wpkh sig pk
    (PayWitnessScriptHash{}, ScriptHashInput i o)           -> p2wsh i o
    (PayScriptHash{}, ScriptHashInput i o)                  -> p2wsh i o
    _ -> Left "calcWitnessProgram: Invalid segwit SigInput"
  where
    p2wpkh sig = return . P2WPKH . WitnessProgramPKH sig
    p2wsh i o  = return . P2WSH $ WitnessProgramSH (simpleInputStack i) (encodeOutput o)

-- | Create the witness stack required to spend a standard P2WSH input
--
-- @since 0.11.0.0
simpleInputStack :: SimpleInput -> [ByteString]
simpleInputStack = \case
    SpendPK sig       -> [f sig]
    SpendPKHash sig k -> [f sig, S.encode k]
    SpendMulSig sigs  -> "" : fmap f sigs
  where
    f TxSignatureEmpty = ""
    f sig              = encodeTxSig sig
