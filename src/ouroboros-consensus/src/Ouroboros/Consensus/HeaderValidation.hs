{-# LANGUAGE DefaultSignatures    #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Header validation
module Ouroboros.Consensus.HeaderValidation (
    validateHeader
    -- * Annotated tips
  , AnnTip(..)
  , annTipHash
  , annTipPoint
  , castAnnTip
  , HasAnnTip(..)
  , getAnnTip
    -- * Header state
  , HeaderState(..)
  , headerStateTip
  , headerStatePush
  , genesisHeaderState
  , castHeaderState
  , rewindHeaderState
    -- * Validate header envelope
  , BasicEnvelopeValidation(..)
  , HeaderEnvelopeError(..)
  , castHeaderEnvelopeError
  , ValidateEnvelope(..)
    -- * Errors
  , HeaderError(..)
  , castHeaderError
    -- * Serialization
  , defaultEncodeAnnTip
  , defaultDecodeAnnTip
  , encodeAnnTipIsEBB
  , decodeAnnTipIsEBB
  , encodeHeaderState
  , decodeHeaderState
  ) where

import           Codec.CBOR.Decoding (Decoder)
import           Codec.CBOR.Encoding (Encoding, encodeListLen)
import           Codec.Serialise (Serialise, decode, encode)
import           Control.Monad.Except
import           Data.Foldable (toList)
import           Data.Proxy
import           Data.Sequence.Strict (StrictSeq ((:<|), (:|>), Empty))
import qualified Data.Sequence.Strict as Seq
import           Data.Typeable (Typeable)
import           Data.Void (Void)
import           GHC.Generics (Generic)

import           Cardano.Binary (enforceSize)
import           Cardano.Prelude (NoUnexpectedThunks)
import           Cardano.Slotting.Slot

import           Ouroboros.Network.Block hiding (Tip (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract (Ticked)
import           Ouroboros.Consensus.Protocol.Abstract
import qualified Ouroboros.Consensus.Util.CBOR as Util.CBOR

{-------------------------------------------------------------------------------
  Preliminary: annotated tip
-------------------------------------------------------------------------------}

-- | Annotated information about the tip of the chain
--
-- The annotation is the additional information we need to validate the
-- header envelope. Under normal circumstances no additional information is
-- required, but for instance for Byron we need to know if the previous header
-- was an EBB.
data AnnTip blk = AnnTip {
      annTipSlotNo  :: !SlotNo
    , annTipBlockNo :: !BlockNo
    , annTipInfo    :: !(TipInfo blk)
    }
  deriving (Generic)

deriving instance HasAnnTip blk => Show               (AnnTip blk)
deriving instance HasAnnTip blk => Eq                 (AnnTip blk)
deriving instance HasAnnTip blk => NoUnexpectedThunks (AnnTip blk)

annTipHash :: forall blk. HasAnnTip blk => AnnTip blk -> HeaderHash blk
annTipHash = tipInfoHash (Proxy @blk) . annTipInfo

annTipPoint :: forall blk. HasAnnTip blk => AnnTip blk -> Point blk
annTipPoint annTip@AnnTip{..} = BlockPoint annTipSlotNo (annTipHash annTip)

castAnnTip :: TipInfo blk ~ TipInfo blk' => AnnTip blk -> AnnTip blk'
castAnnTip AnnTip{..} = AnnTip{..}

class ( StandardHash blk
      , Show               (TipInfo blk)
      , Eq                 (TipInfo blk)
      , NoUnexpectedThunks (TipInfo blk)
      ) => HasAnnTip blk where
  type TipInfo blk :: *
  type TipInfo blk = HeaderHash blk

  -- | Extract 'TipInfo' from a block header
  getTipInfo :: Header blk -> TipInfo blk

  -- | The tip info must at least include the hash
  tipInfoHash :: proxy blk -> TipInfo blk -> HeaderHash blk

  default tipInfoHash :: (TipInfo blk ~ HeaderHash blk)
                      => proxy blk -> TipInfo blk -> HeaderHash blk
  tipInfoHash _ = id

  default getTipInfo :: (TipInfo blk ~ HeaderHash blk, HasHeader (Header blk))
                     => Header blk -> TipInfo blk
  getTipInfo = blockHash

getAnnTip :: (HasHeader (Header blk), HasAnnTip blk)
          => Header blk -> AnnTip blk
getAnnTip hdr = AnnTip {
      annTipSlotNo  = blockSlot  hdr
    , annTipBlockNo = blockNo    hdr
    , annTipInfo    = getTipInfo hdr
    }

{-------------------------------------------------------------------------------
  State
-------------------------------------------------------------------------------}

-- | State required to validate the header
--
-- See 'validateHeader' for details
data HeaderState blk = HeaderState {
      -- | Protocol-specific state
      headerStateConsensus :: !(ConsensusState (BlockProtocol blk))

      -- | The most recent @k@ tips
    , headerStateTips      :: !(StrictSeq (AnnTip blk))

      -- | Tip /before/ 'headerStateTips'
    , headerStateAnchor    :: !(WithOrigin (AnnTip blk))
    }
  deriving (Generic)

headerStateTip :: HeaderState blk -> WithOrigin (AnnTip blk)
headerStateTip HeaderState{..} =
    case headerStateTips of
      Empty     -> headerStateAnchor
      _ :|> tip -> At tip

headerStatePush :: forall blk.
                   SecurityParam
                -> ConsensusState (BlockProtocol blk)
                -> AnnTip blk
                -> HeaderState blk
                -> HeaderState blk
headerStatePush (SecurityParam k) state newTip HeaderState{..} =
    case trim pushed of
      Nothing                   -> HeaderState state pushed  headerStateAnchor
      Just (newAnchor, trimmed) -> HeaderState state trimmed (At newAnchor)
  where
    pushed :: StrictSeq (AnnTip blk)
    pushed = headerStateTips :|> newTip

    trim :: StrictSeq (AnnTip blk) -> Maybe (AnnTip blk, StrictSeq (AnnTip blk))
    trim (newAnchor :<| trimmed) | Seq.length trimmed >= fromIntegral k =
        Just (newAnchor, trimmed)
    trim _otherwise = Nothing

deriving instance (BlockSupportsProtocol blk, HasAnnTip blk)
                => Show (HeaderState blk)
deriving instance (BlockSupportsProtocol blk, HasAnnTip blk)
                => NoUnexpectedThunks (HeaderState blk)
deriving instance ( BlockSupportsProtocol blk
                  , HasAnnTip blk
                  , Eq (ConsensusState (BlockProtocol blk))
                  ) => Eq (HeaderState blk)

genesisHeaderState :: ConsensusState (BlockProtocol blk) -> HeaderState blk
genesisHeaderState state = HeaderState state Seq.Empty Origin

castHeaderState :: (   ConsensusState (BlockProtocol blk )
                     ~ ConsensusState (BlockProtocol blk')
                   , TipInfo blk ~ TipInfo blk'
                   )
                => HeaderState blk -> HeaderState blk'
castHeaderState HeaderState{..} = HeaderState{
      headerStateConsensus = headerStateConsensus
    , headerStateTips      = castSeq castAnnTip $ headerStateTips
    , headerStateAnchor    = fmap    castAnnTip $ headerStateAnchor
    }
  where
    -- This is unfortunate. We're doing busy-work on a strict-sequence,
    -- mapping a function that actually doesn't change anything :/
    castSeq :: (a -> b) -> StrictSeq a -> StrictSeq b
    castSeq f = Seq.fromList . map f . toList

-- | Rewind the header state
--
-- This involves 'rewindChainState', and so inherits its PRECONDITION that the
-- target point must have been previously applied.
--
rewindHeaderState :: forall blk.
                     ( BlockSupportsProtocol blk
                     , Serialise (HeaderHash blk)
                     , HasAnnTip blk
                     )
                  => TopLevelConfig blk
                  -> Point blk
                  -> HeaderState blk -> Maybe (HeaderState blk)
rewindHeaderState cfg p HeaderState{..} = do
    consensusState' <- rewindConsensusState
                         (Proxy @(BlockProtocol blk))
                         (configSecurityParam cfg)
                         p
                         headerStateConsensus
    return $ HeaderState {
        headerStateConsensus = consensusState'
      , headerStateTips      = Seq.dropWhileR rolledBack headerStateTips
      , headerStateAnchor    = headerStateAnchor
      }
  where
    -- the precondition ensures that @p@ is either in the old 'headerStateTips'
    -- or the new 'headerStateTips' should indeed be empty
    rolledBack :: AnnTip blk -> Bool
    rolledBack t = annTipPoint t /= p

{-------------------------------------------------------------------------------
  Validate header envelope
-------------------------------------------------------------------------------}

data HeaderEnvelopeError blk =
    -- | Invalid block number
    --
    -- We record both the expected and actual block number
    UnexpectedBlockNo !BlockNo !BlockNo

    -- | Invalid slot number
    --
    -- We record both the expected (minimum) and actual slot number
  | UnexpectedSlotNo !SlotNo !SlotNo

    -- | Invalid hash (in the reference to the previous block)
    --
    -- We record the current tip as well as the prev hash of the new block.
  | UnexpectedPrevHash !(WithOrigin (HeaderHash blk)) !(ChainHash blk)

    -- | Block specific envelope error
  | OtherHeaderEnvelopeError !(OtherHeaderEnvelopeError blk)
  deriving (Generic)

deriving instance (ValidateEnvelope blk) => Eq   (HeaderEnvelopeError blk)
deriving instance (ValidateEnvelope blk) => Show (HeaderEnvelopeError blk)
deriving instance (ValidateEnvelope blk, Typeable blk)
               => NoUnexpectedThunks (HeaderEnvelopeError blk)

castHeaderEnvelopeError :: ( HeaderHash blk ~ HeaderHash blk'
                           , OtherHeaderEnvelopeError blk ~ OtherHeaderEnvelopeError blk'
                           )
                        => HeaderEnvelopeError blk -> HeaderEnvelopeError blk'
castHeaderEnvelopeError = \case
    OtherHeaderEnvelopeError err         -> OtherHeaderEnvelopeError err
    UnexpectedBlockNo  expected actual   -> UnexpectedBlockNo  expected actual
    UnexpectedSlotNo   expected actual   -> UnexpectedSlotNo   expected actual
    UnexpectedPrevHash oldTip   prevHash -> UnexpectedPrevHash oldTip (castHash prevHash)

-- | Ledger-independent envelope validation (block, slot, hash)
class HasAnnTip blk => BasicEnvelopeValidation blk where
  -- | The block number of the first block on the chain
  expectedFirstBlockNo :: proxy blk -> BlockNo
  expectedFirstBlockNo _ = BlockNo 0

  -- | Next block number
  expectedNextBlockNo :: proxy blk
                      -> TipInfo blk -- ^ Old tip
                      -> TipInfo blk -- ^ New block
                      -> BlockNo -> BlockNo
  expectedNextBlockNo _ _ _ = succ

  -- | The smallest possible 'SlotNo'
  --
  -- NOTE: This does not affect the translation between 'SlotNo' and 'EpochNo'.
  -- "Ouroboros.Consensus.HardFork.History" for details.
  minimumPossibleSlotNo :: Proxy blk -> SlotNo
  minimumPossibleSlotNo _ = SlotNo 0

  -- | Minimum next slot number
  minimumNextSlotNo :: proxy blk
                    -> TipInfo blk -- ^ Old tip
                    -> TipInfo blk -- ^ New block
                    -> SlotNo -> SlotNo
  minimumNextSlotNo _ _ _ = succ

  -- | Compare hashes
  checkPrevHash :: proxy blk
                -> HeaderHash blk  -- ^ Old tip
                -> HeaderHash blk  -- ^ Prev hash of new block
                -> Bool
  checkPrevHash _ = (==)

-- | Validate header envelope
class ( BasicEnvelopeValidation blk
      , Eq                 (OtherHeaderEnvelopeError blk)
      , Show               (OtherHeaderEnvelopeError blk)
      , NoUnexpectedThunks (OtherHeaderEnvelopeError blk)
      ) => ValidateEnvelope blk where

  -- | A block-specific error that 'validateEnvelope' can return.
  type OtherHeaderEnvelopeError blk :: *
  type OtherHeaderEnvelopeError blk = Void

  -- | Do additional envelope checks
  additionalEnvelopeChecks :: TopLevelConfig blk
                           -> Ticked (LedgerView (BlockProtocol blk))
                           -> Header blk
                           -> Except (OtherHeaderEnvelopeError blk) ()
  additionalEnvelopeChecks _ _ _ = return ()

-- | Validate the header envelope
validateEnvelope :: forall blk. (ValidateEnvelope blk, HasHeader (Header blk))
                 => TopLevelConfig blk
                 -> Ticked (LedgerView (BlockProtocol blk))
                 -> WithOrigin (AnnTip blk) -- ^ Old tip
                 -> Header blk
                 -> Except (HeaderEnvelopeError blk) ()
validateEnvelope cfg ledgerView oldTip hdr = do
    unless (actualBlockNo == expectedBlockNo) $
      throwError $ UnexpectedBlockNo expectedBlockNo actualBlockNo
    unless (actualSlotNo >= expectedSlotNo) $
      throwError $ UnexpectedSlotNo expectedSlotNo actualSlotNo
    unless (checkPrevHash' (annTipHash <$> oldTip) actualPrevHash) $
      throwError $ UnexpectedPrevHash (annTipHash <$> oldTip) actualPrevHash
    withExcept OtherHeaderEnvelopeError $
      additionalEnvelopeChecks cfg ledgerView hdr
  where
    checkPrevHash' :: WithOrigin (HeaderHash blk)
                   -> ChainHash blk
                   -> Bool
    checkPrevHash' Origin GenesisHash    = True
    checkPrevHash' (At h) (BlockHash h') = checkPrevHash p h h'
    checkPrevHash' _      _              = False

    actualSlotNo   :: SlotNo
    actualBlockNo  :: BlockNo
    actualPrevHash :: ChainHash blk

    actualSlotNo   =            blockSlot     hdr
    actualBlockNo  =            blockNo       hdr
    actualPrevHash = castHash $ blockPrevHash hdr

    expectedSlotNo :: SlotNo -- Lower bound only
    expectedSlotNo =
        case oldTip of
          Origin -> minimumPossibleSlotNo p
          At tip -> minimumNextSlotNo p (annTipInfo tip)
                                        (getTipInfo hdr)
                                        (annTipSlotNo tip)

    expectedBlockNo  :: BlockNo
    expectedBlockNo =
        case oldTip of
          Origin -> expectedFirstBlockNo p
          At tip -> expectedNextBlockNo p (annTipInfo tip)
                                          (getTipInfo hdr)
                                          (annTipBlockNo tip)

    p = Proxy @blk

{-------------------------------------------------------------------------------
  Errors
-------------------------------------------------------------------------------}

-- | Invalid header
data HeaderError blk =
    -- | Invalid consensus protocol fields
    HeaderProtocolError !(ValidationErr (BlockProtocol blk))

    -- | Failed to validate the envelope
  | HeaderEnvelopeError !(HeaderEnvelopeError blk)
  deriving (Generic)

deriving instance (BlockSupportsProtocol blk, ValidateEnvelope blk)
               => Eq                 (HeaderError blk)
deriving instance (BlockSupportsProtocol blk, ValidateEnvelope blk)
               => Show               (HeaderError blk)
deriving instance (BlockSupportsProtocol blk, ValidateEnvelope blk)
               => NoUnexpectedThunks (HeaderError blk)

castHeaderError :: (   ValidationErr (BlockProtocol blk )
                     ~ ValidationErr (BlockProtocol blk')
                   ,   HeaderHash blk
                     ~ HeaderHash blk'
                   ,   OtherHeaderEnvelopeError blk
                     ~ OtherHeaderEnvelopeError blk'
                   )
                => HeaderError blk -> HeaderError blk'
castHeaderError (HeaderProtocolError e) = HeaderProtocolError e
castHeaderError (HeaderEnvelopeError e) = HeaderEnvelopeError $
                                            castHeaderEnvelopeError e

{-------------------------------------------------------------------------------
  Validation proper
-------------------------------------------------------------------------------}

-- | Header validation
--
-- Header validation (as opposed to block validation) is done by the chain sync
-- client: as we download headers from other network nodes, we validate those
-- headers before deciding whether or not to download the corresponding blocks.
--
-- Before we /adopt/ any blocks we have downloaded, however, we will do a full
-- block validation. As such, the header validation check can omit some checks
-- (provided that we do those checks when we do the full validation); at worst,
-- this would mean we might download some blocks that we will reject as being
-- invalid where we could have detected that sooner.
--
-- For this reason, the header validation currently only checks two things:
--
-- o It verifies the consensus part of the header.
--
--   For example, for Praos this means checking the VRF proofs.
--
-- o It verifies the 'HasHeader' part of the header.
--
--   By default, we verify that
--
--   x Block numbers are consecutive
--   x The block number of the first block is 'firstBlockNo'
--   x Slot numbers are strictly increasing
--   x The slot number of the first block is at least 'minimumPossibleSlotNo'
--   x Hashes line up
--
-- /If/ a particular ledger wants to verify additional fields in the header,
-- it will get the chance to do so in 'applyLedgerBlock', which is passed the
-- entire block (not just the block body).
validateHeader :: (BlockSupportsProtocol blk, ValidateEnvelope blk)
               => TopLevelConfig blk
               -> Ticked (LedgerView (BlockProtocol blk))
               -> Header blk
               -> HeaderState blk
               -> Except (HeaderError blk) (HeaderState blk)
validateHeader cfg ledgerView hdr st = do
    withExcept HeaderEnvelopeError $
      validateEnvelope cfg ledgerView (headerStateTip st) hdr
    consensusState' <- withExcept HeaderProtocolError $
                         updateConsensusState
                           (configConsensus cfg)
                           ledgerView
                           (validateView (configBlock cfg) hdr)
                           (headerStateConsensus st)
    return $ headerStatePush
               (configSecurityParam cfg)
               consensusState'
               (getAnnTip hdr)
               st

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

defaultEncodeAnnTip :: TipInfo blk ~ HeaderHash blk
                    => (HeaderHash blk -> Encoding)
                    -> (AnnTip     blk -> Encoding)
defaultEncodeAnnTip encodeHash AnnTip{..} = mconcat [
      encodeListLen 4
    , encode     annTipSlotNo
    , encodeHash annTipInfo
    , encode     annTipBlockNo
      -- TODO: Useless field. Remove when OK to break binary compatibility.
    , encodeInfo ()
    ]
  where
    encodeInfo :: () -> Encoding
    encodeInfo = encode

defaultDecodeAnnTip :: TipInfo blk ~ HeaderHash blk
                    => (forall s. Decoder s (HeaderHash blk))
                    -> (forall s. Decoder s (AnnTip     blk))
defaultDecodeAnnTip decodeHash = do
    enforceSize "AnnTip" 4
    annTipSlotNo  <- decode
    annTipInfo    <- decodeHash
    annTipBlockNo <- decode
      -- TODO: Useless field. Remove when OK to break binary compatibility.
    ()            <- decodeInfo
    return AnnTip{..}
  where
    decodeInfo :: forall s. Decoder s ()
    decodeInfo = decode

encodeAnnTipIsEBB :: TipInfo blk ~ (HeaderHash blk, IsEBB)
                  => (HeaderHash blk -> Encoding)
                  -> (AnnTip     blk -> Encoding)
encodeAnnTipIsEBB encodeHash AnnTip{..} = mconcat [
      encodeListLen 4
    , encode     annTipSlotNo
    , encodeHash (fst annTipInfo)
    , encode     annTipBlockNo
    , encodeInfo (snd annTipInfo)
    ]
  where
    encodeInfo :: IsEBB -> Encoding
    encodeInfo = encode

decodeAnnTipIsEBB :: TipInfo blk ~ (HeaderHash blk, IsEBB)
                  => (forall s. Decoder s (HeaderHash blk))
                  -> (forall s. Decoder s (AnnTip     blk))
decodeAnnTipIsEBB decodeHash = do
    enforceSize "AnnTip" 4
    annTipSlotNo  <- decode
    hash          <- decodeHash
    annTipBlockNo <- decode
    isEBB         <- decodeInfo
    return AnnTip{annTipInfo = (hash, isEBB), ..}
  where
    decodeInfo :: forall s. Decoder s IsEBB
    decodeInfo = decode

encodeHeaderState :: (ConsensusState (BlockProtocol blk) -> Encoding)
                  -> (AnnTip      blk -> Encoding)
                  -> (HeaderState blk -> Encoding)
encodeHeaderState encodeConsensusState
                  encodeAnnTip'
                  HeaderState{..} = mconcat [
      encodeListLen 3
    , encodeConsensusState headerStateConsensus
    , Util.CBOR.encodeSeq        encodeAnnTip' headerStateTips
    , Util.CBOR.encodeWithOrigin encodeAnnTip' headerStateAnchor
    ]

decodeHeaderState :: (forall s. Decoder s (ConsensusState (BlockProtocol blk)))
                  -> (forall s. Decoder s (AnnTip      blk))
                  -> (forall s. Decoder s (HeaderState blk))
decodeHeaderState decodeConsensusState decodeAnnTip' = do
    enforceSize "HeaderState" 3
    headerStateConsensus <- decodeConsensusState
    headerStateTips      <- Util.CBOR.decodeSeq        decodeAnnTip'
    headerStateAnchor    <- Util.CBOR.decodeWithOrigin decodeAnnTip'
    return HeaderState{..}
