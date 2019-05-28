{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeOperators     #-}
module Network.Robonomics.Lighthouse.SimpleMatcher where

import           Control.Monad.Logger        (MonadLogger, logDebug, logInfo)
import           Control.Monad.Trans         (lift)
import           Data.Base58String.Bitcoin   (Base58String, toBytes)
import           Data.Hashable               (Hashable (..))
import           Data.IntMap                 (delete, insert, size, (!?))
import           Data.Solidity.Prim          (Address, Bytes, UIntN)
import qualified Data.Text                   as T (pack)
import           GHC.TypeLits
import           Pipes                       (Pipe, await, yield)

import           Network.Robonomics.InfoChan (Msg (..))
import           Network.Robonomics.Message  (Demand (..), Offer (..), Report)

instance (KnownNat n, n <= 256) => Hashable (UIntN n) where
    hash = hash . toInteger
    hashWithSalt x = hashWithSalt x . hash

instance Hashable Address where
    hash = hash . show
    hashWithSalt x = hashWithSalt x . hash

instance Hashable Bytes where
    hash = hash . show
    hashWithSalt x = hashWithSalt x . hash

instance Hashable Base58String where
    hash = hash . toBytes
    hashWithSalt x = hashWithSalt x . hash

matchOrders :: MonadLogger m => Pipe Msg (Demand, Offer) m ()
matchOrders = go mempty mempty
  where
    toKey = \case
        MkDemand Demand{..} -> hash demandModel `hashWithSalt` demandObjective
                                                `hashWithSalt` demandLighthouse
                                                `hashWithSalt` demandToken
                                                `hashWithSalt` demandCost
        MkOffer Offer{..}   -> hash offerModel `hashWithSalt` offerObjective
                                               `hashWithSalt` offerLighthouse
                                               `hashWithSalt` offerToken
                                               `hashWithSalt` offerCost
        _ -> 0

    go !asks !bids = do
        lift $ $logInfo $ "Message queue size: " <> T.pack (show (size asks, size bids))

        msg <- await
        lift $ $logInfo $ "Received message: " <> T.pack (show msg)

        let key = toKey msg
        lift $ $logDebug $ "Message key: " <> T.pack (show key)

        case msg of
          MkDemand ask ->
              case bids !? key of
                  Nothing -> go (insert key ask asks) bids
                  Just bid -> do yield (ask, bid)
                                 lift $ $logInfo $ "Matched: " <> T.pack (show (ask, bid))
                                 go asks (delete key bids)

          MkOffer bid ->
              case asks !? key of
                    Nothing -> go asks (insert key bid bids)
                    Just ask -> do yield (ask, bid)
                                   lift $ $logInfo $ "Matched: " <> T.pack (show (ask, bid))
                                   go (delete key asks) bids

          _ -> go asks bids
