{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module RON.Data.LWW
    ( LwwPerField (..)
    , assignField
    , hasField
    , lwwType
    , newFrame
    , viewField
    , zoomField
    ) where

import           RON.Internal.Prelude

import           Control.Error (fmapL)
import           Control.Monad.Except (MonadError)
import           Control.Monad.State.Strict (MonadState, StateT, get, put,
                                             runStateT)
import           Control.Monad.Writer.Strict (lift, runWriterT, tell)
import qualified Data.Map.Strict as Map

import           RON.Data.Internal
import           RON.Event (Clock, advanceToUuid, getEventUuid)
import           RON.Types (Atom (AUuid), Object (..), Op (..), StateChunk (..),
                            StateFrame, UUID)
import qualified RON.UUID as UUID

lww :: Op -> Op -> Op
lww = maxOn opEvent

-- | Key is 'opRef', value is the original op
newtype LwwPerField = LwwPerField (Map UUID Op)
    deriving (Eq, Monoid, Show)

instance Semigroup LwwPerField where
    LwwPerField fields1 <> LwwPerField fields2 =
        LwwPerField $ Map.unionWith lww fields1 fields2

instance Reducible LwwPerField where
    reducibleOpType = lwwType

    stateFromChunk ops =
        LwwPerField $ Map.fromListWith lww [(opRef op, op) | op <- ops]

    stateToChunk (LwwPerField fields) = mkStateChunk $ Map.elems fields

lwwType :: UUID
lwwType = fromJust $ UUID.mkName "lww"

newFrame :: Clock clock => [(UUID, I Replicated)] -> clock (Object a)
newFrame fields = collectFrame $ do
    payloads <- for fields $ \(_, I value) -> newRon value
    e <- lift getEventUuid
    tell $ Map.singleton (lwwType, e) $ StateChunk e
        [Op e name p | ((name, _), p) <- zip fields payloads]
    pure e

viewField :: Replicated a => UUID -> StateChunk -> StateFrame -> Either String a
viewField field StateChunk{..} frame =
    fmapL (("LWW.viewField " <> show field <> ":\n") <>) $ do
        let ops = filter ((field ==) . opRef) stateBody
        Op{..} <- case ops of
            []   -> Left $ unwords ["no field", show field, "in lww chunk"]
            [op] -> pure op
            _    -> Left "unreduced state"
        fromRon opPayload frame

assignField
    :: forall a m
    .   ( ReplicatedAsObject a
        , Clock m, MonadError String m, MonadState (Object a) m
        )
    => UUID -> I Replicated -> m ()
assignField field (I value) = do
    obj@Object{..} <- get
    StateChunk{..} <- either throwError pure $ getObjectStateChunk obj
    advanceToUuid stateVersion
    let chunk = filter ((field /=) . opRef) stateBody
    e <- getEventUuid
    (p, frame') <- runWriterT $ newRon value
    let newOp = Op e field p
    let chunk' = sortOn opRef $ newOp : chunk
    let state' = StateChunk e chunk'
    put Object
        { objectFrame =
            Map.insert (objectOpType @a, objectId) state' objectFrame <> frame'
        , ..
        }

zoomField
    :: (ReplicatedAsObject outer, MonadError String m)
    => UUID -> StateT (Object inner) m a -> StateT (Object outer) m a
zoomField field innerModifier = do
    obj@Object{..} <- get
    StateChunk{..} <- either throwError pure $ getObjectStateChunk obj
    let ops = filter ((field ==) . opRef) stateBody
    Op{..} <- case ops of
        []   -> throwError $ unwords ["no field", show field, "in lww chunk"]
        [op] -> pure op
        _    -> throwError "unreduced state"
    innerObjectId <- case opPayload of
        [AUuid oid] -> pure oid
        _           -> throwError "bad payload"
    let innerObject = Object innerObjectId objectFrame
    (a, Object{objectFrame = objectFrame'}) <-
        lift $ runStateT innerModifier innerObject
    put Object{objectFrame = objectFrame', ..}
    pure a

-- | Check if field is present and is not empty.
hasField
    :: (ReplicatedAsObject a, MonadError String m, MonadState (Object a) m)
    => UUID -> m Bool
hasField field = do
    obj@Object{..} <- get
    StateChunk{..} <- either throwError pure $ getObjectStateChunk obj
    pure $ any (\Op{..} -> opRef == field && not (null opPayload)) stateBody
