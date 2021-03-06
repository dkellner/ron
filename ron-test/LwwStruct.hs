{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module LwwStruct (prop_lwwStruct) where

import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Data.String.Interpolate.IsString (i)
import           GHC.Stack (withFrozenCallStack)
import           Hedgehog (MonadTest, Property, evalEither, property, (===))
import           Hedgehog.Internal.Property (failWith)

import           RON.Data (getObject, newObject)
import qualified RON.Data.ORSet as ORSet
import qualified RON.Data.RGA as RGA
import           RON.Event (ReplicaId, applicationSpecific)
import           RON.Event.Simulation (runNetworkSim, runReplicaSim)
import           RON.Text (parseObject, serializeObject)
import           RON.Util (ByteStringL)

import           LwwStruct.Types (Example1 (..), int1_assign, opt5_read,
                                  opt6_assign, opt6_read, set4_zoom, str2_zoom,
                                  str3_assign, str3_read)

example0 :: Example1
example0 = Example1
    { int1 = 275
    , str2 = "275"
    , str3 = "190"
    , set4 = mempty
    , opt5 = Nothing
    , opt6 = Just 74
    }

-- | "r3pl1c4"
replica :: ReplicaId
replica = applicationSpecific 0xd83d30067100000

ex1expect :: ByteStringL
ex1expect = [i|
    *lww    #B/00009ISodW+r3pl1c4   @`                  !
                                                :int1   =275
                                                :opt5   >none
                                                :opt6   >some =74
                                                :set4   >(1KqirW
                                                :str2   >(6FAycW
                                                :str3   '190'

    *rga    #(6FAycW                @(4pX_g8    :0      !
                                    @)6                 '2'
                                    @)7                 '7'
                                    @)8                 '5'

    *set    #(1KqirW                @`                  !
    .
    |]

ex4expect :: ByteStringL
ex4expect = [i|
    *lww    #B/00009ISodW+r3pl1c4   @`(c1l2MW               !
                                    @(D81V2W    :int1       =166
                                    @`          :opt5       >none
                                    @(c1l2MW    :opt6       >none
                                    @`          :set4       >(1KqirW
                                                :str2       >(6FAycW
                                    @(PEddUW    :str3       '206'

            #(YD2ZdW                @`          :0          !
                                                :int1       =135
                                                :opt5       >none
                                                :opt6       >none
                                                :set4       >(T6VGUW
                                                :str2       >(XvcLcW
                                                :str3       '137'

    *rga    #(6FAycW                @(LxA_UW    :0          !
                                    @(4pX_g6    :`(E4W2MW   '2'
                                    @)7         :(HTTXUW    '7'
                                    @(LJJfUW    :0          '1'
                                    @[xA_UW                 '4'
                                    @(4pX_g8                '5'

            #(XvcLcW                @(X530g8                !
                                    @)6                     '1'
                                    @)7                     '3'
                                    @)8                     '6'

    *set    #(1KqirW                @(asoV2W                !
                                    @                       >(YD2ZdW

            #(T6VGUW                @`                      !
    .
    |]

example4expect :: Example1
example4expect = Example1
    { int1 = 166
    , str2 = "145"
    , str3 = "206"
    , set4 = [Example1
        { int1 = 135
        , str2 = "136"
        , str3 = "137"
        , set4 = []
        , opt5 = Nothing
        , opt6 = Nothing
        }]
    , opt5 = Nothing
    , opt6 = Nothing
    }

prop_lwwStruct :: Property
prop_lwwStruct = property $ do
    -- create an object
    let ex1 = runNetworkSim $ runReplicaSim replica $ newObject example0
    let (oid, ex1s) = serializeObject ex1
    prep ex1expect === prep ex1s

    -- parse newly created object
    ex2 <- evalEitherS $ parseObject oid ex1s
    ex1 === ex2

    -- decode newly created object
    example3 <- evalEither $ getObject ex2
    example0 === example3

    -- apply operations to the object (frame)
    ((str3Value, opt5Value, opt6Value), ex4) <-
        evalEither $
        runNetworkSim $ runReplicaSim replica $ runExceptT $
        (`runStateT` ex2) $ do
            -- plain field
            int1_assign 166
            str2_zoom $ RGA.edit "145"
            str3Value <- str3_read
            str3_assign "206"
            set4_zoom $
                void $ ORSet.addNewRef
                    Example1
                        { int1 = 135
                        , str2 = "136"
                        , str3 = "137"
                        , set4 = []
                        , opt5 = Nothing
                        , opt6 = Nothing
                        }
            opt5Value <- opt5_read
            opt6Value <- opt6_read
            opt6_assign Nothing
            pure (str3Value, opt5Value, opt6Value)
    str3Value === "190"
    opt5Value === Nothing
    opt6Value === Just 74

    -- decode object after modification
    example4 <- evalEither $ getObject ex4
    example4expect === example4

    -- serialize object after modification
    prep ex4expect === prep (snd $ serializeObject ex4)

  where
    prep = filter (not . null) . map BSLC.words . BSLC.lines

evalEitherS :: (MonadTest m, HasCallStack) => Either String a -> m a
evalEitherS = \case
    Left  x -> withFrozenCallStack $ failWith Nothing x
    Right a -> pure a
